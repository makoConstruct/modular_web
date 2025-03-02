// defines a protocol for a distributed type system and some basic types within it, and operations for updating remote objects
// as far as we're aware [haven't actively searched, comparing primarily to capnp, lexicon], this is the most powerful distributed type system ever defined
// but it is not the most sophisticated protocol. We haven't thought about transactions over multiple objects.

// ## about the dart version
// we implement entities as structures over components. Components can be accessed against a single type. Using Dart's inheritance system to represent multiple inheritance heirarchies isn't always possible due to dart's name collision issues: Codegen'd entitty types generally cannot extend all of their component types. The extension relation can be represented in the data but not always in the dart binding.
// this file consists mostly of bootstrapping of the basic types needed to run parsers and evaluate type paramtizations. Once we have that, all further types should be defined and generated using the DSL.

import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'package:cbor/cbor.dart';
import 'package:crypto/crypto.dart';
import 'package:set_list/set_list.dart';

import 'interpreter.dart';
// import 'package:multiformats/multiformats.dart';

// import 'package:macros/macros.dart';

// macro class GubboFunctionality implements ClassDeclarationsMacro, ClassDefinitionMacro {
//   const GubboFunctionality();

//   @override
//   Future<void> buildDeclarationsForClass(
//       ClassDeclaration clazz, MemberDeclarationBuilder builder) async {
//     final methods = await builder.methodsOf(clazz);
//     final theMethod = methods.firstWhereOrNull((m)=> m.identifier.name == "gubben");
//     if(theMethod != null){
//       builder.report(Diagnostic(
//           DiagnosticMessage(
//               'class already has a gubben method, which prevents GubboFunctionality macro from working',
//               target: theMethod.asDiagnosticTarget),
//           Severity.error));
//     }
//     builder.declareInType(DeclarationCode.fromString("int gubben();"));
//   }

//   @override
//   Future<void> buildDefinitionForClass(ClassDeclaration clazz, TypeDefinitionBuilder builder) async {
//     final methods = await builder.methodsOf(clazz);
//     final theMethod =
//         methods.firstWhereOrNull((c) => c.identifier.name == 'gubben');
//     if (theMethod == null) return;
//     final methodBuilder = await builder.buildMethod(theMethod.identifier);
//     methodBuilder.augment(FunctionBodyCode.fromString("{ return 2; }"));
//   }
// }

typedef CID = Uint8List;

enum OPSegmentKind implements Comparable<OPSegmentKind> {
  cid,
  parent,
  indexing;

  @override
  int compareTo(OPSegmentKind other) => index.compareTo(other.index);
  
  // also consider adding: type_component, a type that matches against the first component that has that type
  static OPSegmentKind fromInt(int v) {
    switch (v) {
      case 0:
        return OPSegmentKind.cid;
      case 1:
        return OPSegmentKind.parent;
      case 2:
        return OPSegmentKind.indexing;
      default:
        throw StateError("unknown OP segment variant");
    }
  }
}

int compareUint8List(Uint8List a, Uint8List b) {
  if(a.length != b.length) {
    return a.length.compareTo(b.length);
  }
  for (int i = 0; i < a.length; i++) {
    int c = a[i].compareTo(b[i]);
    if (c != 0) {
      return c;
    }
  }
  return 0;
}

class OPSegment implements Comparable<OPSegment> {
  OPSegmentKind kind;
  Uint8List? hash;
  int? index;
  OPSegment(this.kind, {this.hash, this.index});
  CborValue toCbor({bool shouldTagLink = true}) {
    switch (kind) {
      case OPSegmentKind.cid:
        return CborList(
            [CborInt(BigInt.zero), cidToCbor(hash!, shouldTagLink)]);
      case OPSegmentKind.parent:
        return CborList([CborInt(BigInt.one)]);
      case OPSegmentKind.indexing:
        return CborList([CborInt(BigInt.two), CborInt(BigInt.from(index!))]);
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is OPSegment) {
      return kind == other.kind && hash == other.hash && index == other.index;
    }
    return false;
  }
  
  @override
  int compareTo(OPSegment other) {
    if (kind != other.kind) {
      return kind.compareTo(other.kind);
    }
    if(kind == OPSegmentKind.indexing) {
      return index!.compareTo(other.index!);
    }
    if(kind == OPSegmentKind.cid) {
      return compareUint8List(hash!, other.hash!);
    }
    if(kind == OPSegmentKind.parent) {
      return 0;
    }
    return 0;
  }

  static OPSegment parse(CborValue v) {
    final sg = assumeParseList(v);
    if(sg.length < 1){
      throw AssertionError("Ref segments should be lists with at least one element");
    }
    if(sg[0] is! CborInt) {
      throw AssertionError("expected a CborInt");
    }
    final kind = OPSegmentKind.fromInt((sg[0] as CborInt).toInt());
    if(kind == OPSegmentKind.cid) {
      if(sg.length < 2) {
        throw AssertionError("Ref cid segments should be lists with two elements");
      }
      final second = cidFromCbor(sg[1]);
      return OPSegment(kind, hash: second);
    }
    if(kind == OPSegmentKind.parent) {
      return OPSegment(kind);
    }
    if(kind == OPSegmentKind.indexing) {
      if(sg.length < 2) {
        throw AssertionError("Ref indexing segments should be lists with two elements");
      }
      if(sg[1] is! CborInt) {
        throw AssertionError("second part of a Ref indexing segment should be a CborInt");
      }
      return OPSegment(kind, index: (sg[1] as CborInt).toInt());
    }
    throw AssertionError("unknown Ref segment variant");
  }
}

int compareList<T extends Comparable>(List<T> a, List<T> b) {
  for (int i = 0; i < a.length; i++) {
    int c = a[i].compareTo(b[i]);
    if (c != 0) {
      return c;
    }
  }
  return 0;
}

/// Object Path. (Relative) paths are needed to point at any objects involved in cycles, so all refs are represented as paths just in case.
class Ref<T extends Obj> implements Comparable<Ref<T>> {
  Uint8List? serialization;
  late final List<OPSegment> segments;
  Ref(CID v) : segments = [OPSegment(OPSegmentKind.cid, hash: v)];
  Ref.intoBurl(CID burl, int index) {
    this.segments = [
      OPSegment(OPSegmentKind.cid, hash: burl),
      OPSegment(OPSegmentKind.indexing, index: index)
    ];
  }
  Ref.sameBurl(int index) {
    this.segments = [
      OPSegment(OPSegmentKind.parent),
      OPSegment(OPSegmentKind.indexing, index: index)
    ];
  }
  Ref._empty() : segments = [];
  Ref.fromList(List<OPSegment> segments) : segments = segments;
  static final Ref empty = Ref._empty();

  @override operator==(Object other) {
    if(other is! Ref) { return false; }
    if(segments.length != other.segments.length) { return false; }
    for(int i = 0; i < segments.length; i++) {
      if(segments[i] != other.segments[i]) { return false; }
    }
    return true;
  }
  
  @override
  int compareTo(Ref<T> other) {
    return compareList(segments, other.segments);
  }

  Uint8List get serialized {
    if (serialization != null) {
      return serialization!;
    } else {
      final vv = BytesBuilder(copy: false);
      CborList(segments.map((s) => s.toCbor()).toList());
      serialization = vv.toBytes();
      return serialization!;
    }
  }

  CborValue toCbor() {
    List<CborValue> ol = [];
    for (final s in segments) {
      // we only use the CID cbor tag on the first link, as later links will be key entries and wont need to be cached.
      ol.add(s.toCbor(shouldTagLink: ol.isEmpty));
    }
    return CborList(ol);
  }

  /// any reference from a burled object needs to be checked
  /// If you're not automatically deserializing the link, you want to make sure there are no same_burl links laying around in the tree, as those can't be dereferenced without keeping track of the context. Remember to convert back on deserialize.
  // OP<T> explicitize(CID? burlID){
  //   if(burlID == null){ return this; }
  //   if(OPSegmentKind.fromInt(r.v) == OPSegmentKind.indexing){
  //     final int index = decodeVarint(v, r.nOffset).v;
  //     return OP.into_burl(burlID, index);
  //   }else{
  //     return this;
  //   }
  // }

  @override
  bool operator ==(Object other) {
    return other is Ref && segments == other.segments;
  }
  
  static Ref parse(CborValue v) {
    final vv = assumeParseList(v);
    return Ref.fromList(vv.map((e) => OPSegment.parse(e)).toList());
  }
}

//yoinked from multihash
encodeVarint(int v, BytesBuilder to) {
  if (v < 0) {
    throw ArgumentError.value(
      v,
      'v',
      'must be a non-negative integer',
    );
  }
  do {
    int temp = v & 0x7F; // 0x7F = 01111111
    v = v >> 7; // unsigned bit-right shift
    if (v != 0) {
      temp |= 0x80;
    }
    to.addByte(temp);
  } while (v != 0);
  return to.toBytes();
}

class DecodedVarInt {
  final int v;
  final int nOffset;
  DecodedVarInt({required this.v, required this.nOffset});
}

DecodedVarInt decodeVarint(Uint8List buf, [int? nOffset]) {
  int res = 0;
  int offset = nOffset ?? 0;
  int shift = 0;
  int b;
  final int l = buf.length;

  do {
    if (offset >= l || shift > 49) {
      throw RangeError('Could not decode varint.');
    }

    b = buf[offset++];

    if (shift < 28) {
      res += (b & 0x7F) << shift;
    } else {
      res += (b & 0x7F) * pow(2, shift).toInt();
    }

    shift += 7;
  } while (b >= 0x80);

  return DecodedVarInt(v: res, nOffset: offset);
}

const int rawID = 0x55;
// atproto-conformant CIDs
CID makeCID(Uint8List v, {int type = rawID}) {
  const cidVersion = 0x01;
  const sha256ID = 0x12;
  var b = BytesBuilder(copy: false);
  b.add([cidVersion]);
  b.add([type]);
  b.add(encodeVarint(sha256ID, b));
  var hash = sha256.convert(v).bytes;
  // 256 bits
  b.add(encodeVarint(min(hash.length, 32), b));
  b.add(hash.take(32).toList());
  return b.takeBytes();
}

Uint8List cborBinary(CborValue v) => Uint8List.fromList(cbor.encode(v));

CborValue cborNully(CborValue? v) => v ?? CborNull();

CID cborID(Uint8List v) => makeCID(v, type: 0x71);

CID blobID(Uint8List v) => makeCID(v, type: rawID);

CID hashAddress(Uint8List data) {
  return cborID(data);
}

final int ipldLinkTag = 42;
CborValue cidToCbor(CID cid, [bool shouldTagLink = true]) {
  final vv = BytesBuilder(copy: false);
  // 0 because: https://ipld.io/specs/codecs/dag-cbor/spec/#links "In DAG-CBOR, Links are the binary form of a CID encoded using the raw-binary identity Multibase. That is, the Multibase identity prefix (0x00) is prepended to the binary form of a CID and this new byte array is encoded into CBOR as a byte-string"
  vv.addByte(0);
  vv.add(cid);
  return CborBytes(vv.toBytes(), tags: shouldTagLink ? [ipldLinkTag] : []);
}

CID cidFromCbor(CborValue v) {
  if(v is! CborBytes) {
    throw AssertionError("expected a CborBytes");
  }
  if(!v.tags.contains(ipldLinkTag)) {
    throw AssertionError("missing IPLD link tag (0x2a)");
  }
  if(v.bytes.first != 0x00) {
    throw AssertionError("expected multibase identity prefix (0x00) in CID");
  }
  return Uint8List.fromList(v.bytes.sublist(1));
}

// // we can't store IDs as statics in types because dart didn't think we'd need trait statics
// WeakMap<List<Obj>, (ID, ParametizedType)> memoizedTypes = WeakMap();
// ID typeID<T extends Obj>() {
//   var t = T;
//   ID r = typeIDs[t];
//   if (r == null) {
//     r = typeIDs[t] = t.type.id;
//   }
//   return r;
// }

/// whenever you build an object and want to resolve its id and serialization, a SerializationState is involved.
/// most of the work it does relates to cycles in serialization and producing burl objects as needed.
/// orders things in reverse DFS over trace order, which entails that dependencies will always come before the dependent, which is pretty useful wouldn't you say

class UncommittedObjectError extends StateError {
  UncommittedObjectError(super.message);
}

typedef TypeMap = SplayTreeMap<Ref<TType>, Obj>;

/// a distributed object that can be published, referred to by relations, cached or pinned in a local database
/// for Dart, making Objs fully immutable isn't possible, but they should generally behave as if they are immutable.
/// note, many fields in Obj (mainly those that are Obj or contain Objs) must be `late`, as any Obj can participate in cycles due to intersection types (If type A links to a type B, then an A&B referring to another A&B forms a cycle).
/// Most Objs you receive are a component of a larger object. You can gain access to the whole object through `ancestor`. The ref is taken from `ancestor`.
abstract class Obj {
  late final Eobj family;
  Obj get totalRoot => family.root;

  Ref get ref => family.ref;

  TypeMap? _components;

  /// The components of this object. EG, if this class inherited Int, directly or indirectly, then there would be an Int entry in `components`.
  TypeMap get components {
    if (_components == null) {
      _components = SplayTreeMap();
      _populateComponentTable(_components!);
    }
    return _components!;
  }

  /// The components of the overall object this is part of, not necessarily inherited by this component seeing.
  TypeMap get familyCompnents => family.root.components;

  /// instance data of the objects this inherits
  late final List<Obj> extending;

  // this is late just because the TypeType needs to be its own type
  late final TType type;
  
  String? get rootName => (type.family[std.nameType] as Name?)?.name;

  /// the rough amount of memory this object takes up
  int roughSize = 100;

  Obj({TType? type, List<Obj>? extending}) {
    if (type != null) {
      this.type = type;
    }
    if (extending != null) {
      this.extending = extending;
    }
  }

  void _populateComponentTable(TypeMap table) {
    table.putIfAbsent(type.ref as Ref<TType>, () => this);
    for (Obj o in extending) {
      o._populateComponentTable(table);
    }
  }

  /// visit all of the objects that are 'part of' this one. Doesn't necessarily require listing every object link contained, only the ones that're important for this object's functionality.
  void traceComponent(Function(Obj) visitor);

  /// traceComponent and also recursing into the extends heirarchy
  void _traceAll(Function(Obj) visitor) {
    traceComponent(visitor);
    for (Obj ext in extending) {
      ext._traceAll(visitor);
    }
  }

  void trace(Function(Obj) visitor) {
    family.trace(visitor);
  }

  /// the entity representation, which consists of a list of components, each of which is a pair of a type ref and a cbor value. If you only expect your object to have one component, then inherit Ubj instead of Obj. Ubj's `toCbor` has a simpler signature.
  CborValue toCbor();
}

class Burl extends Obj {
  List<Obj> content;
  Burl(this.content) : super(type: std.burlType);
  @override
  void traceComponent(Function(Obj) visitor) {
    content.forEach(visitor);
  }

  @override
  CborValue toCbor() {
    return CborList(content.map((o) => o.ref.toCbor()).toList());
  }
}

/// Entity, or Entire Object. The root ancestor of a component object (Obj) heirarchy, from which the Ref was calculated.
/// the type of an Eobj is indeterminate for two very good reasons.
/// - One is that your code shouldn't care what the type of the root ancestor is, one of the great properties of the apc protocol is that anyone can add additional components to a type and you can still grab the component you want even if you know nothing about those other components. Your code should never reuqire the Obj's Eobj to be a particular type.
/// - Another reason is that we use that mechanism to add a nonce when necessary, so we don't know whether this will be a nonced type or not until it's serialized.
class Eobj {
  final Obj root;
  Ref? _ref;
  BigInt nonce = BigInt.zero;

  /// we expose this when you already have the ID on construction (IE, when you were sent an object) so that it doesn't have to be computed again
  /// should usually only be called via a batch ID assignment to account for knots, though batch assignments may need to assign more than once, first a local ref, second the burl ref.
  assignID(Ref v) {
    _ref = v;
  }

  /// getter because ID is generated after construction.
  Ref get ref => _ref != null
      ? _ref!
      : throw UncommittedObjectError(
          "attempt to access the Ref of an object that hasn't been published yet. Remember to use uplink.commit(this) soon after object construction.");
  Eobj({required this.root}) {
    void assignAncestor(Obj o) {
      o.family = this;
      for (Obj ext in o.extending) {
        assignAncestor(ext);
      }
    }

    assignAncestor(root);
  }
  
  Obj? operator [](TType t) => root.components[t];

  Eobj get ancestor => this;

  // where does the nonce go?
  CborValue toCbor() {
    CborValue ret = root.toCbor();
    if (nonce != BigInt.zero) {
      (ret as CborList).add(CborInt(nonce));
    }
    return ret;
  }

  void trace(Function(Obj) visitor) {
    root._traceAll(visitor);
  }
}

class FileObj extends Obj {
  final String name;
  final Uint8List content;
  FileObj(this.name, this.content) : super(type: std.fileType);

  String stringContent() => String.fromCharCodes(content);

  @override
  CborValue toCbor() {
    return CborList([CborString(name), CborBytes(content)]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {}
}

// this was written as an example of inheritance. But I can't be bothered defining stringFileObj, so it's not a real type.

// class StringFileObj extends Obj implements FileObj {
//   final FileObj file;
//   String get name => file.name;
//   Uint8List get content => file.content;
//   String stringContent() => file.stringContent();
//   StringFileObj(String name, String content)
//       : file = FileObj(name, Uint8List.fromList(content.codeUnits)),
//         super(type: std.stringFileObj) {
//     extending = [file];
//   }

//   @override
//   CborValue toCbor() {
//     // adds no additional fields
//     return CborList([]);
//   }

//   @override
//   void traceComponent(Function(Obj) visitor) {}
// }

int roughSize(o) {
  if (o == null) {
    return 0;
  } else if (o is Iterable) {
    return 8 * 4 + o.length * 8 + o.map(roughSize).fold(0, (a, b) => a + b);
  } else if (o is Obj) {
    return o.roughSize;
  } else if (o is (dynamic, dynamic)) {
    return roughSize(o.$1) + roughSize(o.$2);
  } else {
    throw Exception("we don't know the size of this object");
  }
}

//so that methods that are also called roughSize can call roughSize
const roughSizeDyn = roughSize;

// I notice that a Cell(obj) can make any immutable object mutable and a Snapshot(obj) makes any mutable object immutable

// enum ProcessEditOutcome {
//   Success,
//   InvalidEdit,
//   TooOld;
//   String description(){
//     switch (this) {
//       case Success:
//         return "valid edit";
//       case InvalidEdit:
//         return "This edit isn't valid given the history we know. We can assume that the server has more events that would make this event make sense. For now, we'll ignore an invalidedit and compute a state from the other events. Note that this is sometimes very tricksy, as previous (seemingly valid) edits could be what's causing this event to invalidate, rather than it being the fault of this edit, and later events may be interpreted differently as a result of its invalidation.";
//       case TooOld:
//         return "the event was too old, we don't have the part of the event history it fits into, so we're going to have to do a sync with the server instead of processing the event.";
//     }
//   }
// }

// [l1]
// class HistoryEntry {
//   SlotEdit edit;
//   Obj? state;
//   HistoryEntry(this.edit, {this.state}) {}
// }
// class ProcessingResult {
//   List<SlotEdit> errors;
//   Obj newState;
//   ProcessingResult({required this.errors, required this.newState}) {}
// }
/// a distributed object that is a function of an edit log. Buffers edits and snapshots to allow fast and consistent integration of out of order events.
/// [todo]: make a Log object and redefine this as Logstate&ltState, E&gt that takes a Log&ltE&gt and an initial State. Not all mutable objects will be Logstates. Logs are kind of more fundamental in some ways more complex to deal with. Other mutable objects could exist which are bastards who aren't eventually consistent. All an object has to be to qualify as a tasteweb mutable object is it has to have a websocket interface and it has to be fully defined and typed by the tasteweb objects at its content address.
/// a mutable object can be made immutable with a no-permission update rule, so sometimes when you need to abstract over mutability status you will inherit from MutableObj
// abstract class Actor<T extends Obj> extends Obj {
//   // every mutable obj is made up of a succession of Objs. We keep a record of recent edits so that if an edit we didn't know about sneaks in from a few seconds ago we'll be able to validate and integrate it efficiently. If we can't integrate the edit, then we have to request the current state from the server again.
//   // some of these edits may be invalid. At least one has to be kept as the oldest edit (at index 0) for us to tell whether a new edit is newer or not. Snapshots will be deleted in such a way as to maintain a guarantee of O(log(distance_travelling_back)) currently we just keep every valid edit, so only invalid edits will have null state.

//   // initial declaration stuff, may be overpowered by later goings on
//   final DateTime creationTime;
//   final T initialState;
//   final TType stateType;
//   final UpdateRule initialUpdateRule;

//   Actor({
//       required this.creationTime,
//       required this.initialState,
//       required this.initialUpdateRule,
//       T? currentState,
//       required this.log,
//       required this.state,
//       required this.stateType,
//       required this.updateRule,
//   })
//       : super(Std.actorType){

//       }

//   @override
//   CborValue toCbor() => CborList([
//     CborDateTimeInt(creationTime),
//     initialState.ref.toCbor(),
//     stateType.ref.toCbor(),
//     initialUpdateRule.toCbor(),
//   ]);

//   List<HistoryEntry> log;
//   // [todo] how the hell do we know when to dispose this? (why does it need to be disposed) Can we just use the autodispose feature? Why wouldn't we always use it?
//   ValueNotifier<Obj> state;
//   UpdateRule updateRule;
//   // [todo] shouldn't we track which edits were errors? Why the hell not?

//   @override
//   int get roughSize {
//     return log.fold(
//             8 * 3, (a, p) => a + roughSizeDyn(p.edit) + roughSizeDyn(p.state)) +
//         roughSizeDyn(state.value);
//   }

//   /// validates then returns the new obj or null iff the edit was invalid for this state
//   Obj? applyEdit(Obj state, SlotEdit e){
//     return updateRule.apply(state, e);
//   }

//   /// as the length of the edit history gets longer, we may retain fewer snapshots.
//   /// this currently just okays every index, but more sophisticated policies might be added later (see the historical file `toying with exponential falloff for snapshots.dart`). I wanted something that retained at 0, then retained a number of snapshots/states that's logarithmic on the number of retained events, so never too large. But for persisted data structures that hardly seems necessary. When we start having to deal with non persisted datastructures, we'll want to use a mutating applyEdit and only clone out snapshots when necessary. Oh, but note, if you implement that, don't keep a very high concentration of snapshots at the front. You shouldn't clone on every frame. If this approach is to be useful, then you need to not be cloning on every frame.
//   bool willRetainSnapshotAt(int at, int length) {
//     return true;
//   }

//   /// the currentState may update even if the return value is InvalidEdit, in cases where an earlier event invalidates a later one. The return value will be InvalidEdit if any of the edits we remember are invalid. This makes the InvalidEdit return value a little bit useless, since it only describes the edits we remember and can't necessarily attribute blame to one edit or another, since an edit can butt in with an older timestamp and invalidate later edits that were previously valid.
//   /// returns the list of all invalid edits after e. Empty list means success, no errors. Null return means the edit was too old to integrate and you're going to have to do a full state sync with the network (must be handled!). For a simpler API use `processEdit`, which arranges the sync automatically if needed.
//   /// doesn't update listeners to this object
//   List<SlotEdit>? _tryProcessEdit(SlotEdit e) {
//     //first find the insertiont point
//     for (var i = log.length - 1; i >= 0; --i) {
//       var cmp = log[i].edit.compareTo(e);
//       if (cmp == 0) {
//         //this edit is equal to an existing edit and so has already been processed (this shouldn't happen often? should it emit a warning?)
//         return [];
//       } else if (cmp < 0) {
//         //insertion point found
//         int newLogLength = log.length + 1;
//         //seek most recent state before that
//         for (var si = i; si >= 0; --si) {
//           var curState = log[si].state;
//           if (curState != null) {
//             //end loop
//             var retentionPredicate =
//                 (at) => willRetainSnapshotAt(at, newLogLength);
//             List<SlotEdit> errorEdits = [];
//             curState =
//                 _combFrom(errorEdits, curState, si, i, retentionPredicate);

//             // delete this, it was replaced by the above. Same below. Committing once for posterity.
//             // List<Edit> errorEdits = [];
//             // //run it forward to get the state before our event
//             // //replace the following with _combThrough, as well as the end block
//             // while(si < i){
//             //   final re = log[si];
//             //   final edo = applyEdit(curState!, re.edit);
//             //   if(edo != null){
//             //     curState = edo;
//             //   }else{
//             //     // we don't report invalid edits from before e, as this would make error reporting highly unpredictable, and you will have received a report of those errors already.
//             //     // and we ignore invalid edits, leave curState while still moving onto the next edit
//             //   }
//             //   //but we do need to overwrite history either way
//             //   log[si].state = willRetainSnapshotAt(si, newLogLength) ? edo : null;
//             //   ++si;
//             // }

//             //insert here
//             var theNovelState = applyEdit(curState, e);
//             //propagate error if needed
//             if (theNovelState == null) {
//               errorEdits.add(e);
//             }
//             ++si;
//             log.insert(
//                 si,
//                 HistoryEntry(e,
//                     state: willRetainSnapshotAt(si, newLogLength)
//                         ? theNovelState
//                         : null));
//             //continue running it forward

//             var finalState = _combFrom(errorEdits, theNovelState ?? curState,
//                 si, log.length, retentionPredicate);

//             // if(theNovelState != null){
//             //   curState = theNovelState;
//             // }
//             // ++si;
//             // for(; si<log.length; ++si){
//             //   var re = log[si];
//             //   var ns = applyEdit(curState!, re.edit);
//             //   if(ns == null){
//             //     errorEdits.add(re.edit);
//             //   }else{
//             //     curState = ns;
//             //   }
//             //   re.state = willRetainSnapshotAt(si, newLogLength) ? curState : null;
//             // }
//             //we're done. Report.
//             // currentState.value = curState!;
//             state.value = finalState;

//             return errorEdits;
//           }
//         }
//         // then there were no snapshots old enough, which shouldn't happen
//         throw AssertionError(
//             "critical error: there was no snapshot older than the oldest event we remember, mutable object id: ${this.ref}, this exception should never be seen");
//       }
//     }
//     // there was no event in our memory that was older than this one, so we don't know where to work it into the history and can't process it.
//     return null;
//   }

//   // may need to call to the network to resync
//   Future<List<SlotEdit>> _processEdit(Uplink n, SlotEdit e) async {
//     var ret = _tryProcessEdit(e);
//     if (ret == null) {
//       return await _sync(n, 20);
//     } else {
//       return ret;
//     }
//   }

//   /// updates states, and emits the curState
//   Obj _combFrom(List<SlotEdit> errorOut, Obj curState,
//       int fromEvent, int beforeEvent, bool Function(int) snapshotPredicate) {
//     var i = fromEvent;
//     do {
//       var rh = log[i];
//       rh.state = snapshotPredicate(i) ? curState : null;
//       var ns = applyEdit(curState, rh.edit);
//       if (ns == null) {
//         errorOut.add(rh.edit);
//       } else {
//         curState = ns;
//       }
//       ++i;
//     } while (i < beforeEvent);
//     return curState;
//   }

//   /// writes over the current event log with the network's version. Need to do this when joining the network or when we get a very old event we're unable to merge in that's still valid for some reason.
//   /// returns the invalid edits
//   Future<List<SlotEdit>> _sync(Uplink n, int eventLogLength) async {
//     (Obj, List<SlotEdit>) backlog =
//         await n.fetchWithBacklog(ref, eventLogLength);
//     List<SlotEdit> errors = [];
//     log = backlog.$2.map((e) => HistoryEntry(e, state: null)).toList();
//     log[0].state = backlog.$1;
//     state.value = _combFrom(errors, backlog.$1, 0, eventLogLength,
//         (at) => willRetainSnapshotAt(at, eventLogLength));
//     return errors;
//   }
// }

// @immutable
// class UpdateRule extends Obj {
//   final bool reversionAllowed;
//   final TType typeConstraint;
//   // able to change the writers set, owners set, and to revert changes
//   final UserGroup owners;
//   // able to publish events
//   final UserGroup writers;
//   // able to subscribe and read the latest version
//   final UserGroup readers;
//   UpdateRule({
//     this.reversionAllowed = true,
//     required this.typeConstraint,
//     required this.owners,
//     required this.writers,
//     required this.readers,
//   }): super(Std.);
//   Obj? apply(Obj state, Edit e){
//     return null;

//   }
//   @override CborValue toCbor() {

//   }
// }

// class UserGroup extends Obj {
//   UserGroup(HashSet<User> users): super() {}
// }

// bool isOrContains(Permissionable p, ID u) {}

// class PermissionInclude extends Permission {
//   final Permissionable p;
//   PermissionInclude(this.p);
//   bool includes(UserIdentity user) => isOrContains(p, user.ref);
// }

// @immutable
// class UserProfile extends Obj {
//   final String name;
//   final ID? introduction;
//   UserProfile(super.type, this.name, this.introduction);
//   CborValue toCbor() => CborList([
//         CborString(name),
//         CborTag(introduction),
//       ]);
// }

// // represents a person to whom permissions can be granted
// class UserIdentity extends Actor<UserProfile> {}

// tombstone: We don't need immutable objs. Basically all objects are immutable in a sense. Mutable objs actually use a separate system to represent their mutable aspects.
// /// an immutable obj. In most protocols, immutable is the first kind that's implemented, then special methods are added to allow mutability. In others, mutability is the default, and adding a version number is necessary to refer to an immutable version, and old versions will often be dropped by the host.
// abstract class Obj extends Obj {
//   Obj(TType type) : super(type) {}
//   // [todo] implement roughSize. It should be cached (the object is immutable)
//   // Snapshot<Self> snapshot() { ... }
// }


List<CborValue> assumeParseList(CborValue value, [int? length]) {
  if(value is CborList) {
    final v = value.toList();
    if(length != null && v.length != length) {
      throw AssertionError("expected $length elements in a CborList");
    }
    return v;
  }
  throw AssertionError("CborList expected here in Obj parse");
}

class TypeList extends SetList<TType> {
  TypeList(List<TType> v) : super(v);
  static comparator(TType a, TType b) {
    // todo: sort such that parametrics of the same term together, so that a search can be done on the term, and then each result can be checked for variance supertyping.
    return a.compareTo(b);
  }
}

/// a concrete type
abstract class TType extends Obj implements Comparable<TType> {
  /// iff true, encoded without a vtable/type information
  late final bool raw = false;
  late final bool nonced = true;
  late final int girth;
  late final SetList<TType> typeExtending;
  SetList<TType>? _allTypeComponents;
  SetList<TType> get allTypeComponents {
    if(_allTypeComponents == null) {
      _allTypeComponents = SetList([]);
      collectComponents(_allTypeComponents!);
      _allTypeComponents!.v.sort();
    }
    return _allTypeComponents!;
  }
  void collectComponents(SetList<TType> out) {
    for(final t in typeExtending.v) {
      out.add(t);
      t.collectComponents(out);
    }
  }
  TType({SetList<TType>? typeExtending, super.extending}) : super(type: std.typeType) {
    if (typeExtending != null) {
      this.typeExtending = typeExtending;
    } else {
      this.typeExtending = SetList([]);
    }
    girth = this.typeExtending.v.length != 0 ? this.typeExtending.v.map((e) => e.girth).reduce((a, b) => a + b) : 1;
  }
  /// needed for bootstrapping typeType
  TType.noType({SetList<TType>? typeExtending}) {
    if (typeExtending != null) {
      this.typeExtending = typeExtending;
    } else {
      this.typeExtending = SetList([]);
    }
  }
  @override operator==(Object other) {
    if(other is TType) {
      return ref == other.ref;
    }
    return false;
  }
  @override
  int compareTo(TType other) => ref.compareTo(other.ref);
  bool isSubtypeOf(TType other) {
    // todo: make sure eq is using the same thing as compareTo
    // todo: cache all components on every type, not just this one. This is currently quadratic.
    // todo: you're completely failing on parametric types... unless we're currently invariant, which we might be.
    return allTypeComponents.contains(other);
    // wait why did I think I needed to do this...
    // bool ret = true;
    // // most languages have more efficient approaches to this, but we have to deal with a lot of dynamic objects, and also this is a reference implementation and this code is much simpler.
    // // other shouldn't have any components that we don't have
    // typeExtending.comparisonScan(other.typeExtending, onlyInOther: (_){ ret = false; });
    // return ret;
  }
  friendlyName(StringBuffer out);
  // /// required for constructing cyclic structures
  // newUninitialized()
  // initialize(List<Obj>)
  
  /// parsing happens in two phases to accomodate the possibiility of cycles. First allocate the object (you need not do anything else) then in the thunk, the objects that you need will all be available in the Cache so you can complete the initialization of your fields (looking up your Refs and getting the associated Objs). If you try to imagine initializing a pair of objects that refer to each other without a process like this, you will find that it cannot be done, except perhaps with lazy evaluation, but Dart doesn't have that, and this essentially is a phased lazy evaluation..
  (Obj, Function(Obj Function(Ref) resolver)) parse(CborValue value);
}

class Name extends Obj {
  String name;
  Name(this.name) : super(type: std.nameType);
  CborValue toCbor() => CborList([CborString(name)]);
  friendlyName(StringBuffer out) => out.write(name);
  @override
  void traceComponent(Function(Obj) visitor) {}
}

class IntrinsicType extends TType {
  final IntrinsicTypeTag tag;
  final Obj Function(CborValue value) _parse;
  // noType because we need to initialize the type of IntrinsicType typeType late
  IntrinsicType.withoutType(this.tag, this._parse) : super.noType();
  IntrinsicType(this.tag, this._parse);
  @override
  friendlyName(StringBuffer out) {
    out.write(tag.name);
  }

  @override
  CborValue toCbor() {
    // [todo] shouldn't this involve some kind of escaping or type tagging. It's possible it doesn't need to toCbor at all, the type is the whole deal.
    return CborList([CborString("intrinsic"), CborString(tag.name)]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {}

  // we just use a member because defining a different type for each of these would be onerous
  @override
  (Obj, Function(Obj Function(Ref) resolver)) parse(CborValue value) {
    return (_parse(value), (_){});
  }
}


// interpreter stuff

class EnumType extends TType {
  late final List<TType> variants;
  // TType discriminator; // must inherit integer or something
  // late final List<Let> members;
  EnumType({super.typeExtending}): super(extending: [CodeComponent(0)]);
  @override
  friendlyName(StringBuffer out) {
    out.write('(enum');
    out.write(rootName ?? '_');
    out.write(')');
  }
  @override
  void traceComponent(Function(Obj) visitor) {
    for(final v in variants) {
      visitor(v);
    }
  }
  @override
  CborValue toCbor() {
    return CborList([
      // this represents the variables, which I cbf implementing just now
      CborList([]),
      CborList(variants.map((v) => v.ref.toCbor()).toList())
    ]);
  }
  
  @override
  (Obj, Function(Obj Function(Ref) resolver)) parse(CborValue value) {
    final v = assumeParseList(value, 2);
    final ret = EnumType();
    return (ret, (_){});
  }
}

abstract class Code extends Obj {
  /// says enough about the Code obj to help to identify it, but doesn't necessarily try to print the entire thing
  Code(): super(type: std.codeType) {}
  String prettyPrint();
}

class LetType extends TType {
  LetType() : super(typeExtending: SetList([std.codeType]));
  @override
  friendlyName(StringBuffer out) {
    out.write('let');
  }
  @override
  void traceComponent(Function(Obj) visitor) {
    visitor(type);
  }
  @override
  CborValue toCbor() {
    return CborList([type.ref.toCbor()]);
  }
  @override
  (Obj, Function(Obj Function(Ref) resolver)) parse(CborValue value) {
    final v = assumeParseList(value, 1);
    final tr = Ref.parse(v[0]);
    Let ret = Let();
    return (ret, (Obj Function(Ref) resolver){
      return (ret, (){
        ret.bound = resolver(tr) as TType;
      });
    });
  }
}
/// a definition of a variable. Usually has Name and sometimes Description components.
class Let extends Code {
  late final TType bound;
  Let([TType? bound]): super(type: std.letType, extending: SetList([CodeComponent()])) {
    if(bound != null) {
      this.bound = bound;
    }
  }
  @override
  String prettyPrint() => "(let $name)";
  @override
  CborValue toCbor() => CborList([
        CborString("let"),
        CborString(name),
        bound.ref.toCbor(),
      ]);
  @override
  void traceComponent(Function(Obj) visitor) {
    visitor(bound);
  }
  
  @override
  String get name => _name;
}

/// an invocation of a function
class Evaluation extends Code {
  late final FunctionT function;
  late final List<Obj> args;
  Evaluation(this.function, this.args);
  @override
  String prettyPrint() => "(eval ${function.prettyPrint()} ${args.map((e) => e.identify()).join(" ")})";
  @override
  CborValue toCbor() => CborList([
        CborString("eval"),
        function.ref.toCbor(),
        CborList(args.map((e) => e.ref.toCbor()).toList())
      ]);
  @override
  void traceComponent(Function(Obj) visitor) {
    visitor(function);
    for (final arg in args) {
      visitor(arg);
    }
  }
}

class DoBlock extends Code {}

class FunctionT extends Code {
  List<Let> params;
  DoBlock body;
  FunctionT(this.params, this.body) : super(Std.functionType);
  @override
  String prettyPrint() {
    String firstPart =
        this is Name ? "(Function ${(this as Name).name} " : "(Function ";
    String secondPart = "(${params.map((e) => e.prettyPrint()).join(" ")} ...)";
    return "$firstPart$secondPart";
  }

  @override
  CborValue toCbor() => CborList([
        CborList(params.map((e) => e.ref.toCbor()).toList()),
        body.ref.toCbor()
      ]);

  @override
  traceComponent(Function(Obj) visitor) {
    for (Let l in params) {
      l.trace(visitor);
    }
    body.trace(visitor);
  }
}

class CodeComponent extends Obj {
  final int discriminator;
  CodeComponent(this.discriminator) : super(type: std.codeType);
  @override
  CborValue toCbor() => CborList([CborInt(BigInt.from(discriminator))]);
  @override
  void traceComponent(Function(Obj) visitor) {}
}

// class Match extends Code {}

class EvaluationLimitExceeded implements Exception {
  Code at;
  EvaluationLimitExceeded(this.at);
  @override
  String toString() {
    return "Evaluation limit exceeded at ${at.prettyPrint()}";
  }
}

// meditate on the following...
// (struct g (var a) (var b))
// (let a (invoke g.make 1 b))
// (let b (invoke g.make 1 a))

class Runtime {
  int evaluationCount = 0;
  final int evalTimeLimit;
  final Obj program;
  late Obj result;
  // definition, value
  List<Map<Obj, Obj>> stack = [];

  /// evalTimeLimit: The number of evaluations that are allowed before an EvaluationLimitExceeded error will be thrown
  Runtime(this.program, {this.evalTimeLimit = -1}) {}
}

Obj run(Obj program, {int evalTimeLimit = -1}) {
  Runtime runtime = Runtime(program, evalTimeLimit: evalTimeLimit);
  return runtime.result;
}

class FieldInfo {
  late final String name;
  late final TType type;
  late final String description;
  FieldInfo({required this.name, required this.type, this.description = ""});
}

class StructType extends TType {
  final Ref? definition;
  late final List<Let> fields;
  StructType({this.definition, List<Let>? fields}) {
    if (fields != null) {
      this.fields = fields;
    }
  }
  @override
  friendlyName(StringBuffer out) {
    out.write('(');
    bool isFirst = true;
    for (final f in fields) {
      if (!isFirst) {
        out.write(' ');
      }
      isFirst = false;
      out.write('(${f.name} ');
      f.type.friendlyName(out);
      out.write(')');
    }
    out.write(')');
  }

  @override
  CborValue toCbor() {
    return CborList([
      CborString('struct'),
      CborNull(),
      CborList(fields
          .map((f) => CborList([
                CborString(f.name),
                f.type.ref.toCbor(),
              ]))
          .toList())
    ]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    for (FieldInfo fif in fields) {
      visitor(fif.type);
    }
  }
  
  @override
  (Obj, Function(Obj Function(Ref))) parse(CborValue value) {
    List<CborValue> v = assumeParseList(value, 3);
    final ret = StructType(definition: definition);
    return (ret, (Obj Function(Ref) resolver){
      ret.fields = assumeParseList(v[3], null).toList().map((e){
        final el = assumeParseList(e);
        String name;
        TType type;
        return FieldInfo(name: el[0], type: el[1], description: el[2]);
      }).toList();
    });
  }
}

class VarDef extends Obj {
  late final TType type;
  final String name;
  final String description;
  VarDef({TType? type, required this.name, this.description = ""}) {
    if (type != null) {
      this.type = type;
    }
  }
  @override
  CborValue toCbor() {
    return CborList(
        [type.ref.toCbor(), CborString(name), CborString(description)]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    visitor(type);
  }
}

class TypeParameter extends Obj {
  final VarDef def;
  final TypeParameterKind kind;
  TypeParameter(this.def, this.kind);
  @override
  CborValue toCbor() {
    return CborList([def.toCbor(), CborString(kind.toString())]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    visitor(def);
  }
}

class Func extends Obj {
  late final List<VarDef> inputs;
  final String description;
  late final TType outputType;
  Func({List<VarDef>? inputs, TType? outputType, this.description = ""}) {
    if (inputs != null) {
      this.inputs = inputs;
    }
    if (outputType != null) {
      this.outputType = outputType;
    }
  }
  @override
  CborValue toCbor() {
    return CborList([
      CborString("function"),
      CborList(inputs.map((v) => v.toCbor()).toList()),
      outputType.ref.toCbor(),
      CborString(description),
    ]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    for (final v in inputs) {
      visitor(v);
    }
    visitor(outputType);
  }
}

class ParametricField {
  // if parameter, type is unimportant, name corresponds to the parameter def name
  bool get isParameter => type == null && parameterName != null;
  final String name;
  final TType? type;
  final String? parameterName;
  final String description;
  CborValue toCbor() => isParameter
      ? CborList([
          CborString("parameter"),
          CborString(name),
          CborString(parameterName!),
          CborString(description),
        ])
      : CborList([
          CborString("concrete"),
          CborString(name),
          type!.ref.toCbor(),
          CborString(description),
        ]);
  ParametricField(this.name, this.type, this.parameterName,
      {this.description = ""});
}

class ParametricStruct extends ParametricType {
  final List<ParametricField> structFields;
  ParametricStruct(super.definition, super.parameterRequirements,
      this.structFields);
  @override
  CborValue toCbor() {
    return CborList([
      CborString("parametric_struct"),
      CborList(parameterRequirements
          .map((p) => CborList([
                CborString(p.def.name),
                CborString(p.kind.toString()),
                p.def.type.ref.toCbor()
              ]))
          .toList()),
      CborList(structFields.map((f) => f.toCbor()).toList()),
      CborString(rootName ?? "_"),
      cborNully(definition?.toCbor())
    ]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    // `definition` is non-necessary
    for (final r in parameterRequirements) {
      visitor(r.def);
    }
    for (final f in structFields) {
      if (f.type != null) {
        visitor(f.type!);
      }
    }
  }
}

enum TypeParameterKind { instance, subtype }

// These are really not types until you've parametized them. They're a *way of making* types once given the template parameters. ie, they're a bijective const function that takes types and (we're trying to be a dependent type system) vals and returns a type. They also tend to have a name, which they know themselves. But that can just be a Name trait that gets added in. So really this should just be a function
abstract class ParametricType extends Obj {
  // the code where it was defined.
  final Ref? definition;
  final List<TypeParameter> parameterRequirements;
  ParametricType(this.definition, this.parameterRequirements)
      : super(type: std.parametizedTypeFunctionType);
}

class ParametizedType extends TType {
  late final ParametricType pt;
  late final List<Obj> parameters;
  late final TType v;
  ParametizedType(this.pt, this.parameters) : super() {
  }
  @override
  friendlyName(StringBuffer out) {
    out.write('(');
    out.write(pt.rootName ?? "_");
    out.write(' ');
    var count = 0;
    for (var obj in parameters) {
      out.write(obj.toString());
      if (count + 1 < parameters.length) {
        out.write(' ');
      }
      count += 1;
    }
    out.write(')');
  }

  @override
  CborValue toCbor() {
    return CborList([
      CborString("parametized_type"),
      pt.ref.toCbor(),
      CborList(parameters.map((o) => o.ref.toCbor()).toList())
    ]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    visitor(pt);
    parameters.forEach(visitor);
  }
}

class IntrinsicParametricType with ParametricType {
  final Name intrinsicName;
  IntrinsicParametricType(String intrinsicName, super.definition,
      List<TypeParameter> parameterRequirements): this.intrinsicName = Name(intrinsicName) ;
  @override
  CborValue toCbor() {
    return CborList([
      CborString("intrinsic"),
      CborString(intrinsicName.name),
      CborList(parameterRequirements
          .map((p) => CborList([
                CborString(p.def.name),
                CborString(p.kind.toString()),
                p.def.type.ref.toCbor()
              ]))
          .toList()),
      cborNully(definition?.toCbor())
    ]);
  }

  @override
  void traceComponent(Function(Obj) visitor) {
    for (final p in parameterRequirements) {
      visitor(p.def.type);
    }
  }
}

late final Std std = Std();

class Std {
  // actually this needs to be an enum
  late final EnumType typeType;
  // wait why is there a struct type type, isn't that just type.
  static late final IntrinsicType staticTypeType;
  late final TType structType;
  static late final TType staticStructType;
  late final TType letType;
  late final TType codeType;
  
  late final IntrinsicType boolType;
  late final IntrinsicType intType;
  late final IntrinsicType stringType;
  late final IntrinsicType anyType;
  late final IntrinsicType blobType;
  late final IntrinsicType nonceType;
  late final StructType nameType;
  late final StructType definitionType;
  late final StructType fileType;
  late final IntrinsicType parametizedTypeFunctionType;
  late final IntrinsicType dateTime;
  late final IntrinsicParametricType vecParametricType;
  late final IntrinsicParametricType slotParametricType;
  late final ParametizedType vecAny;
  late final TType burlType;
  // we leave it mutable so that you can clear it after processing it if you want to?
  List<(Obj, BinaryPresence)> _initialTypeCommits;

  Std() {
    // todo: decide on an order of initialization and make sure the static types are all ready in that order

    /*
    // marks types that were created through a parametric type. Useful for printing the name of the type and for type inference.
    struct Parametized {
      var parameters: List<TypeParameter>
      var on: ParametricType
    }
    
    // many objs have a name
    struct Name {
      var name: String
    }
    
    // types which are guaranteed to evaluate to an object
    enum Code {
      case struct Let {
        var type: Type
      }
      case struct Function {
        var params: List<Let>
        var output: Type
        var body: DoBlock
      }
      case struct DoBlock {
        var body: List<Code>
      }
      case struct Conditional {
        var condition: Code
        var body: Code
        var elseBody: Code?
      }
      case struct Variable {
        var at: Let
      }
      case struct Invocation {
        var function: Function
        var args: List<Code>
      }
      case struct Literal { var value: Obj }
    }
    
    // all types are constructed from these
    enum Type {
      case struct Enum {
        // enums can define members which all variants must inherit from the enum
        var members: List<Let>
        var variants: List<Type>
      }
      case struct Struct {
        var members: List<Let>
      }
      case String
      case Int
      case Bool
      case DateTime
      case Blob
      case Nonce
      case Parametizzed {
        var parameters: List<TypeParameter>
        var on: ParametricType
      }
    }
    */
    
    
    typeType = EnumType();
    staticTypeType = typeType;
    typeType.type = typeType;
    EnumType

    boolType = IntrinsicType(IntrinsicTypeTag.boolType);
    intType = IntrinsicType(IntrinsicTypeTag.intType);
    stringType = IntrinsicType(IntrinsicTypeTag.stringType);
    anyType = IntrinsicType(IntrinsicTypeTag.anyType);
    blobType = IntrinsicType(IntrinsicTypeTag.blobType);
    nonceType = IntrinsicType(IntrinsicTypeTag.nonceType);
    parametizedTypeFunctionType =
        IntrinsicType(IntrinsicTypeTag.parametricType);
    dateTime = IntrinsicType(IntrinsicTypeTag.dateTime);

    vecParametricType = IntrinsicParametricType("vec", "vec", null,
        [TypeParameter(VarDef(type: anyType, name: "T"), TypeParameterKind.subtype)]);

    slotParametricType = IntrinsicParametricType("slot", "slot", null,
        [TypeParameter(VarDef(type: anyType, name: "T"), TypeParameterKind.subtype)]);

    vecAny = ParametizedType(
        IntrinsicParametricType("vec", "vec", null,
            [TypeParameter(VarDef(type: anyType, name: "T"), TypeParameterKind.subtype)]),
        [anyType]);

    burlType = NamedType(
        StructType(name: "burl", fields: [
          FieldInfo(
              name: "contents",
              type: ParametizedType(
                  IntrinsicParametricType("vec", "vec", null,
                      [TypeParameter(VarDef(type: anyType, name: "T"), TypeParameterKind.subtype)]),
                  [anyType]))
        ]));

    fileType = NamedType(
        "file",
        null,
        StructType(fields: [
          FieldInfo(name: "name", type: stringType),
          FieldInfo(name: "content", type: blobType)
        ]));
  }
  initialTypeCommits = commitAll();
  
  // void welcomeCache(Cache cache) {
  // }

  // todo, commit those objects

  // SlotTypeFunction slotParametricType;
  // StructType actorType;
  // // BasicType mutableDeclaration;
  // Std(
  //     {required this.boolType,
  //     required this.intType,
  //     required this.stringType,
  //     required this.anyType,
  //     required this.typeType,
  //     required this.dateTime,
  //     required this.actorType,
  //     required this.parametizedTypeFunctionType,
  //     required this.slotEventParametricType,
  //     required this.vecParametricType,
  //     required this.slotParametricType}) {}
  // // these IDs are wrong, to initialize the IDs you need to already have a binary format.

  // // hmm, I'd like all of these to have definitions... so that we can put documentation there and reference them. But I guess these are content-addressable and maybe that's good enough.
  // static Std init() {

  // [todo] pretty sure we wont need this. Static initialization seems to have no limitations
  //   // tombstone: dart cannot initialize truly immutable data cyclicly
  //   // var typeType = BasicType(BasicTypeTag.typeType, typeType); //Local variable 'typeType' can't be referenced before it is declared.
  //   // so we do it in the following way
  //   var anyType = BasicType(BasicTypeTag.anyType); anyType.type = theTypeType;
  //   var boolType = BasicType(BasicTypeTag.boolType); boolType.type = theTypeType;
  //   var intType = BasicType(BasicTypeTag.intType); intType.type = theTypeType;
  //   var stringType = BasicType(BasicTypeTag.stringType); stringType.type = theTypeType;
  //   var dateTime = BasicType(BasicTypeTag.dateTime); dateTime.type = theTypeType;
  //   var parametizedTypeFunctionType = BasicType(BasicTypeTag.parametricType); parametizedTypeFunctionType.type = theTypeType;
  //   // this should be defined properly as a mere object type. It's time, stop fucking around, define the type language
  //   var slotEventType = ParametricStruct(null, "event", [
  //     TypeParameter(theTypeType, TypeParameterKind.Subtype, "T")
  //   ], [
  //     ParametricField("payload", null, "T"),
  //     ParametricField("timestamp", dateTime, null,
  //         description:
  //             "The time when the sender says they sent the event. Events that are too old may be refused.")
  //   ]);
  //   var vecParametricType = VecTypeFunction();
  //   var slotParametricType = SlotTypeFunction();
  //   return Std(
  //       boolType: boolType,
  //       intType: intType,
  //       stringType: stringType,
  //       anyType: anyType,
  //       dateTime: dateTime,
  //       typeType: theTypeType,
  //       parametizedTypeFunctionType: parametizedTypeFunctionType,
  //       actorType: StructType("mutable declaration", [
  //         FieldInfo("stateType", typeType)
  //         FieldInfo("timestamp", dateTime)
  //         FieldInfo("initialState", anyType)
  //         FieldInfo("updateRule", UpdateRule)
  //       ], null)
  //       vecParametricType: vecParametricType,
  //       slotParametricType: slotParametricType,
  //       slotEventParametricType: slotEventType);
  // }

  void pinToCache(Cache cache) {}
}

class InvalidEdit implements Exception {
  final String message;
  InvalidEdit(this.message);

  @override
  String toString() => 'InvalidEdit: $message';
}

// class IntegerEditType extends TType {
//   IntegerEditType(ID id) : super(id);
//   @override
//   String friendlyName() {
//     return 'integer_edit';
//   }
// }

// sealed class IntegerEdit extends Edit {
//   IntegerEdit(ID id): super(ID id) {}
// }

// class Increment extends IntegerEdit {}

// class Decrement extends IntegerEdit {}

// class SetInteger extends IntegerEdit {
//   final int to;
//   SetInteger(this.to) {}
// }

class IntObj extends Obj {
  int value;
  IntObj(this.value) : super(type: std.intType);
  @override
  CborValue toCbor() => CborInt(BigInt.from(value));
  @override
  void traceComponent(Function(Obj) visitor) {}
}

class StringObj extends Obj {
  String value;
  StringObj(this.value) : super(type: std.stringType);
  @override
  CborValue toCbor() => CborString(value);
  @override
  void traceComponent(Function(Obj) visitor) {}
}

class BoolObj extends Obj {
  bool value;
  BoolObj(this.value) : super(type: std.boolType);
  // string encoding required by IPLD
  @override
  CborValue toCbor() => CborString(value ? "true" : "false");
  @override
  void traceComponent(Function(Obj) visitor) {}
}

// [l1]
// class SlotEdit<T extends Obj> extends Obj {
//   final DateTime timestamp;
//   final Obj newValue;
//   SlotEdit(TType type, this.timestamp, this.newValue) : super(type);
//   @override
//   Object toCbor() {
//     return {'timestamp': timestamp.toIso8601String(), 'value': newValue.ref};
//   }

//   int compareTo(SlotEdit<T> other) {
//     return lexicographicCmps<SlotEdit>(
//         this, other, [(e) => e.timestamp, (e) => e.newValue.ref]);
//   }
// }

// int lexicographicCmps<T>(
//     T a, T b, List<Comparable Function(T)> propertyAccessors) {
//   for (var pa in propertyAccessors) {
//     var cmp = pa(a).compareTo(pa(b));
//     if (cmp != 0) {
//       return cmp;
//     }
//   }
//   return 0;
// }

// [l1]
/// okay this will be a dynamically typed thing for now because I cbf thinking about variance and type checking - wait, no, what, I'm undermining that
/// A mutable object type that just accepts any type-correct assignment operation. This type will be enough for most applications, though it will sometimes have lower performance, and sometimes you want more complex edit rules to prevent edits from being clobbered.
/// [todo] this should have variance inout and we almost got a security bug from the fact that it isn't (if I hadn't noticed it, we would have accepted events for supertypes of T)
// class Slot<T extends Obj> extends Actor {
//   Slot(DateTime timestamp, Permission permission, T initialValue,
//       List<HistoryEntry> log)
//       : super(
//             timestamp,
//             permission,
//             initialValue,
//             Obj.slotUpdateRule,
//             ParametizedType(Std.slotParametricType, [value.type]),
//             value,
//             log) {}
//   @override
//   Obj? applyEdit(Obj _curState, SlotEdit e) {
//     if (e is SlotEdit<T>) {
//       return e.newValue;
//     } else {
//       return null;
//     }
//   }

//   @override
//   Object toCbor() {
//     return {'type': type.ref, 'newValue': state.value.id};
//   }

//   // returns whichever value T says was latest, so might not be yours. Error if you lack write permissions
//   Future<T> write(T nv){

//   }
// }

//things you might want to know in relation to your subscriptions
//we take the ID as a parameter because we want ID types to be fast. Other protocol-specific things don't need to be fast.
// abstract class Event {}

// class EditEvent extends Event {
//   SlotEdit edit;
//   EditEvent(this.edit) {}
// }

// class Publishing extends Event {
//   final Obj published;
//   Publishing(this.published) {}
// }

// class Deletion<ID, Obj> extends Event {
//   final ID of;
//   Deletion(this.of) {}
// }

// /// not necessarily an equal peer, but a host, something which objects can be published to. In many protocols, there will only be one remote host, representing the whole global network in general, but we'll usually provide the option even in that case of just publishing things to your own devices.

// abstract class SubscriptionHandle {}

// @Data()
// class RetentionPolicy {
//   final Duration keepFor;
//   final int priority;
//   final Process? retainer;
// }

/// keeps obs in cache until it's disposed
// class Process extends MutableObj {
//   Uplink ul;
//   Module module;
//   HashSet<Ref> retainedObjects = HashSet();
//   Process(this.ul, this.module);
//   void dispose() {
//     RetentionPolicy(keepFor:Duration.infinite);
//     for(Ref o in retainedObjects){
//       ul.cache.release(o);
//     }
//     ul.processes.remove(this);
//   }
// }

/// descripes where the binary of an object is stored
abstract class BinaryPresence {}

/// it's stored right here
class ImmediateBinaryPresence implements BinaryPresence {
  final Uint8List binary;
  ImmediateBinaryPresence(this.binary);
}

/// means that this object is encoded within the binary of another object, usually a burl
class DependentBinaryPresence implements BinaryPresence {
  final CID containedWithin;
  DependentBinaryPresence(this.containedWithin);
}

List<(Obj, BinaryPresence)> makeCommit(Obj obj) {
  return makeCommitAll([obj]);
}

/// completes ref ids and nonces (or null nonces) of all of the objects linked from roots, returns a list of the new objects
/// ensures that none of the blobs end up with identical refs by adding a nonce component to the ones that clash
/// (another counterintuitive thing it does is it assigns temporary same_burl ids to items within a burl while the items of that burl are being serialized (before toCbor is called) so that toCbor will resolve local links when appropriate. Anyone implementing a toCbor method (everyone) might like to know this, but I really can't foresee a situation where they'd *need* to.)
List<(Obj, BinaryPresence)> makeCommitAll(List<Obj> roots) {
  // List<Eobj> roots = roots.map((e) => Eobj(root: e)).toList();
  // the objects currently being fingered by the depth first search
  for (Obj o in roots) {
    // (registers self in o.ancestor)
    Eobj(root: o);
  }
  List<Obj> stack = [];
  List<Obj> allVisited = [];
  HashMap<Obj, Burl> burlAssignments = HashMap<Obj, Burl>();
  HashSet<Obj> visited = HashSet<Obj>();
  HashSet<Obj> stacked = HashSet<Obj>();

  // optimization todo: use the refs to encode visited state intrusively
  // bool visited(Obj o) => o._ref != null;
  // bool resolved(Obj o) => o._ref != null && o._ref != const Ref.empty && o._ref.segments[0]!.kind != OPSegmentKind.indexing;
  // bool stacked(Obj o) => o._ref != null && o._ref != const Ref.empty && o._ref.segments[0]!.kind == OPSegmentKind.indexing;

  // first identify burls and create an ordering over the unresolved objects that ensure that the dependencies of an object are always either after it or in its burl.
  // consists of a depth first search that reacts when we hit something that's in the current stack (this is how you find cycles)
  void visit(Obj v) {
    if (v.family._ref != null) {
      // it hasn't mutated since acqusiition and doesn't need to be republished
      return;
    }
    if (visited.contains(v)) {
      if (stacked.contains(v)) {
        //cycle detected
        Burl? encompassingBurl;
        //find or create the rootmost burl
        int vi = stack.length - 1;
        for (; vi >= 0; --vi) {
          Obj tv = stack[vi];
          final tb = burlAssignments[tv];
          if (tb != null) {
            encompassingBurl = tb;
          }
          if (tv == v) {
            break;
          }
        }
        encompassingBurl ??= Burl([]);
        // engulf everything in the cycle and any burls they may have already
        for (; vi < stack.length; ++vi) {
          Obj tv = stack[vi];
          final tb = burlAssignments[tv];
          if (tb != null) {
            if (tb != encompassingBurl) {
              //merge them
              for (Obj t in tb.content) {
                burlAssignments[t] = encompassingBurl;
              }
            }
          } else {
            burlAssignments[tv] = encompassingBurl;
          }
        }
      } else {
        // dag/multi-in link detected. But we don't currently do anything with that.. but we will need to in encoding
      }
    } else {
      visited.add(v);
      stack.add(v);
      stacked.add(v);
      allVisited.add(v);
      v.traceComponent(visit);
    }
    stacked.remove(v);
    stack.removeLast();
  }

  for (Obj r in roots) {
    visit(r);
  }
  HashSet<CID> idsSoFar = HashSet<CID>();

  // reify the ids
  // those with no dependencies will be at the beginning, the last root node will be at the end
  List<Burl> populatedBurls = [];
  List<(Obj, BinaryPresence)> ret = [];
  // iterating backwards because it guarantees that burls that are linked by other forming burls will be finalized before they're needed
  // assign everything its burl position
  final burlIndices = HashMap<Obj, int>();
  for (int avi = allVisited.length - 1; avi >= 0; --avi) {
    Obj o = allVisited[avi];
    Burl? b = burlAssignments[o];
    if (b != null) {
      populatedBurls.add(b);
      burlIndices[o] = b.content.length;
      b.content.add(o);
    }
  }
  // now assign IDs
  for (int avi = allVisited.length - 1; avi >= 0; --avi) {
    Obj o = allVisited[avi];
    Burl? b = burlAssignments[o];
    if (b != null) {
      if (b.family._ref == null) {
        //resolve everything in the burl, otherwise, nothing needs to be done, this obj is already resolved

        // temporarily assign same_burl ids so that when this object is referenced in a serialization by the following toCbor calls, it is a local link
        for (int bi = 0; bi < b.content.length; ++bi) {
          b.content[bi].family.assignID(Ref.sameBurl(bi));
        }

        int renoncingCounter = 0;
        Uint8List burlBinary;
        CID burlID;
        do {
          b.family.nonce = renoncingCounter > 0
              ? BigInt.from(renoncingCounter)
              : BigInt.zero;
          ++renoncingCounter;
          CborValue cburl = b.toCbor();
          burlBinary = cborBinary(cburl);
          burlID = cborID(burlBinary);
        } while (idsSoFar.contains(burlID));
        b.family.assignID(Ref(burlID));
        ret.add((b, ImmediateBinaryPresence(burlBinary)));
        for (int boi = 0; boi < b.content.length; ++boi) {
          final id = Ref.intoBurl(burlID, boi);
          Obj bi = b.content[boi];
          bi.family.assignID(id);
          ret.add((bi, DependentBinaryPresence(burlID)));
        }
      }
    } else {
      //isn't in a burl
      Uint8List bin;
      CID id;
      int renoncingCounter = 0;
      // again rehash until it's unique
      do {
        o.family.nonce =
            renoncingCounter > 0 ? BigInt.from(renoncingCounter) : BigInt.zero;
        bin = cborBinary(o.toCbor());
        id = cborID(bin);
        ++renoncingCounter;
      } while (idsSoFar.contains(id));
      o.family.assignID(Ref(id));
      ret.add((o, ImmediateBinaryPresence(bin)));
    }
  }

  return ret;
}

// todo: next thing to do is decide on a caching api and connect makeCommit to it.
/// Initially, this will just be fake and local
/// your interface to "the network", the place where edits are merged and consensus is formed. Currently running on a completely stupid almost entirely centralized protocol that we can pretty cleanly replace later on once a good decentralized protocol surfaces. Mako senses that there are some really incredible decentralized secure compute platforms, soon to arrive, that use trusted execution environments and zkvms, so there's not much point in adopting today's cheap parallel ledger protocols like holochain or freenet since they aren't on that level and since they'd lead to slower UX which is totally intollerable.
/// When The Protocol does arise, it will provide:
/// - 'publish' new objects to the network. `publish`
/// - associate IDs with objects
/// - issue edits to objects (which are themselves addressable objects, though I suppose the address is rarely used)
/// - query its current state. `fetch`
/// - issuing ongoing queries, which could also be described as subscriptions, but they can be quite complex: `subscribeEdits`, `subscribeTree`, etc.
///    - which queries are supported is part of the prtocol definition.
abstract class Uplink {
  // Uri hostDomain = Uri(host:"api.modularweb.app");

  Cache get cache;
  reportObjectSizeChange(Obj obj, int newSize) {
    final obt = cache.liveObjs[obj.ref]!;
    final dif = newSize - obt.roughSize;
    cache.totalMemoryUsed += dif;
    // [[todo]] then you're supposed to check to see whether memoryUsed is outside of acceptable bounds and delete stuff/write to disk if so.
  }

  /// should be of the same type
  // addPeerConnection(Network to);
  // removePeerConnection(Network to);

  Future<Obj> fetch(CID id);

  /// Stream handles should both be able to unsubscribe, and to be persisted to disk (as notification stream definitions). Most should have expiry times.
  /// note, the subscription isn't actually registered with the network until something listens to the stream, but usually you'll do that right away
  Stream<Obj> subscribeEdits(Obj to, Duration? expiry);
  // Future<(Obj, List<SlotEdit>)> fetchWithBacklog(
  //     CID id, int eventLogLength);
  // Stream<Event> subscribeTree(Obj from, CID relType, int hops, Duration? expiry);

  /// returns just the rels
  Stream<Obj> subscribeRel(Obj from, CID relType, Duration? expiry);

  /// (rel, to)
  Stream<(Obj, Obj)> subscribeNeighbor(Obj from, Duration? expiry);
}

/// currently doesn't persist to disk
class Cache {
  /// just an estimate
  int totalMemoryUsed;
  // do we want this?:
  // Map<CID, Obj> baseObjs;
  Map<Ref, Obj> liveObjs;
  // todo disk stuff, and disk cache size management. Sort items by size x rarity of access and remove the top ones of those first when space is needed.
  //    todo allow pinned objects, and weakly pinned objects (eg, objects that your friends posted)
  // /// used in case of an emergency to switch all of our data over to the next known unbroken hash function
  // rehash(newHashFunction)
  Cache()
      : liveObjs = {},
        totalMemoryUsed = 0;
}

enum IntrinsicTypeTag {
  boolType,
  intType,
  stringType,
  anyType,
  typeType,
  parametricType,
  dateTime,
  blobType,
  nonceType; //I don't think this should be a basic type.

  TType get type {
    switch (this) {
      case IntrinsicTypeTag.boolType:
        return std.boolType;
      case IntrinsicTypeTag.intType:
        return std.intType;
      case IntrinsicTypeTag.stringType:
        return std.stringType;
      case IntrinsicTypeTag.anyType:
        return std.anyType;
      case IntrinsicTypeTag.typeType:
        return std.typeType;
      case IntrinsicTypeTag.parametricType:
        return std.parametizedTypeFunctionType;
      case IntrinsicTypeTag.dateTime:
        return std.dateTime;
      case IntrinsicTypeTag.blobType:
        return std.blobType;
      case IntrinsicTypeTag.nonceType:
        return std.nonceType;
    }
  }

  String get name {
    switch (this) {
      case IntrinsicTypeTag.boolType:
        return 'bool';
      case IntrinsicTypeTag.intType:
        return 'int';
      case IntrinsicTypeTag.stringType:
        return 'string';
      case IntrinsicTypeTag.anyType:
        return 'any';
      case IntrinsicTypeTag.typeType:
        return 'type';
      case IntrinsicTypeTag.parametricType:
        return 'parametric_type';
      case IntrinsicTypeTag.dateTime:
        return 'date_time';
      case IntrinsicTypeTag.blobType:
        return 'blob';
      case IntrinsicTypeTag.nonceType:
        return 'nonce';
    }
  }
}

// class InMemoryFakeNetwork extends Uplink {}

/// a node in a wire representation, which will be translated to cbor but maybe something else later
class WireNode {}

/// Checks if you are awesome. Spoiler: you are.
class Awesome {
  bool get isAwesome => true;
}
