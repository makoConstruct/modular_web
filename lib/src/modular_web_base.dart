// defines a protocol for a distributed type system and some basic types within it, and operations for updating remote objects
// as far as we're aware [haven't actively searched, comparing primarily to capnp, lexicon], this is the most powerful distributed type system ever defined
// but it is not the most sophisticated protocol. We haven't thought about transactions over multiple objects.

// ignore_for_file: slash_for_doc_comments

// I guess I want there to be one definition language that's for the machine, nice and succinct, and another for the programmer.
// maybe the following shouldn't be done? The encoding can have external links that relate it to the codebase. After all, it's provable that the codebase maps to that encoding. And many types don't really exist in a codebase, the intrinsics.
// Oh, the problem is, two codebases shouldn't be allowed to define the same type. If they're in different codebases, they should be considered to have different meanings.
/* Types are encoded as obj(
  definition_for_humans: codebaseSnapshotID/objectID //the cid of the item in the codebase that defines this object (the codebase should describe its own language type, which should map to a compiler implementation)
  definition_for_code: typeEncoding //a concise encoding of the type information in the universal language
)
*/
import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'package:cbor/cbor.dart';
import 'package:crypto/crypto.dart';
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

enum OPSegmentKind {
  cid,
  parent,
  indexing;

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

class OPSegment {
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
}

/// Object Path. (Relative) paths are needed to point at any objects involved in cycles, so all refs are represented as paths just in case.
class Ref<T extends Obj> {
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
  static final Ref empty = Ref._empty();

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
}

//yoinked from multihash
encodeVarint(int value, BytesBuilder to) {
  if (value < 0) {
    throw ArgumentError.value(
      value,
      'value',
      'must be a non-negative integer',
    );
  }
  do {
    int temp = value & 0x7F; // 0x7F = 01111111
    value = value >> 7; // unsigned bit-right shift
    if (value != 0) {
      temp |= 0x80;
    }
    to.addByte(temp);
  } while (value != 0);
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

CborValue cidToCbor(CID cid, [bool shouldTagLink = true]) {
  final vv = BytesBuilder(copy: false);
  final int ipldLinkTag = 42;
  vv.addByte(0);
  vv.add(cid);
  return CborBytes(vv.toBytes(), tags: shouldTagLink ? [ipldLinkTag] : []);
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

/// a distributed object that can be published, referred to by relations, cached or pinned in a local database
/// for Dart, making Objs fully immutable isn't possible, but they should generally behave as if they are immutable.
/// note, all fields in Obj should be late, as they're hard to construct without that, and any Obj can participate in cycles due to intersection types (If type A links to a type B, then an A&B referring to another A&B forms a cycle).
abstract class Obj {
  // when the ID is null, it means a mutation has occurred and reserialization may be necessary
  Ref? _ref;

  /// we expose this when you already have the ID on construction (IE, when you were sent an object) so that it doesn't have to be computed again
  /// should usually be called via a batch ID assignment to account for knots.
  assignID(Ref v) {
    _ref = v;
  }

  /// getter because ID is generated after construction.
  Ref get ref => _ref != null
      ? _ref!
      : throw UncommittedObjectError(
          "attempt to access the Ref of an object that hasn't been published yet. Remember to use uplink.commit(this) soon after object construction.");

  // this is late just because the TypeType needs to be its own type and dart can't initialize immutable cyclic types
  late final TType type;
  // sometimes needed to differentiate objects with the same content. Thunks will be introduced automatically if two otherwise identical objects are committed in the same batch.
  late final BigInt? thunk;

  /// the rough amount of memory this object takes up
  int roughSize = 100;

  Obj([TType? type]) {
    if (type != null) {
      this.type = type;
    }
  }

  /// visit all of the objects that are 'part of' this one. Doesn't necessarily require listing every object link contained, only the ones that're important for this object's functionality.
  void trace(Function(Obj) visitor);

  CborValue toCbor();

  // /// recurses over the entire object tree, extracting immutable current state of each mutable object contained into an immutable snapshot. We'll need macros to implement this ergonomically on our side.
  // Obj snapshot();

  // there may need to be a method that completes initialization once cyclic refs are available
  // void completeInitialization();
}

class Burl extends Obj {
  List<Obj> content;
  Burl(this.content) : super(Std.burlType);
  @override
  void trace(Function(Obj p1) visitor) {
    content.forEach(visitor);
  }

  @override
  CborValue toCbor() {
    return CborList(content.map((o) => o.ref.toCbor()).toList());
  }
}

class FileObj extends Obj {
  final String name;
  final Uint8List content;
  FileObj(this.name, this.content) : super(Std.fileType);

  String stringContent() => String.fromCharCodes(content);

  @override
  CborValue toCbor() {
    return CborMap({
      CborString("name"): CborString(name),
      CborString("content"): CborBytes(content),
    });
  }

  @override
  void trace(Function(Obj) visitor) {}
}

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

/// a concrete type
abstract class TType extends Obj {
  TType() : super(Std.typeType);
  TType.noType();
  friendlyName(StringBuffer out);
  // /// required for constructing cyclic structures
  // newUninitialized()
  // initialize(List<Obj>)
}

class NamedType extends TType {
  late final String name;
  late final Ref? definition;
  late final TType? child;
  NamedType(this.name, this.definition, this.child) : super();
  @override
  CborValue toCbor() {
    return CborMap({
      CborString("kind"): CborString("named"),
      CborString("name"): CborString(name),
      CborString("definition"): cborNully(definition?.toCbor()),
      CborString("child"): cborNully(child?.toCbor()),
    });
  }

  @override
  void trace(Function(Obj p1) visitor) {
    if (child != null) {
      visitor(child!);
    }
  }

  @override
  friendlyName(StringBuffer out) {
    out.write(name);
  }
}

class BasicType extends TType {
  final BasicTypeTag tag;
  // noType because we need to initialize the type of BasicType typeType late
  BasicType.withoutType(this.tag) : super.noType();
  BasicType(this.tag);
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
  void trace(Function(Obj p1) visitor) {}
}

class FieldInfo {
  late final String name;
  late final TType type;
  late final String description;
  FieldInfo({required this.name, required this.type, this.description = ""});
}

class StructType extends TType {
  final Ref? definition;
  late final List<FieldInfo> fields;
  StructType({this.definition, List<FieldInfo>? fields}) {
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
    return CborMap({
      CborString('kind'): CborString('struct'),
      CborString('definition'): CborNull(),
      CborString('fields'): CborList(fields
          .map((f) => CborMap({
                CborString('name'): CborString(f.name),
                CborString('type'): f.type.ref.toCbor(),
                CborString('description'): CborString(f.description)
              }))
          .toList()),
    });
  }

  @override
  void trace(Function(Obj p1) visitor) {
    for (FieldInfo fif in fields) {
      visitor(fif.type);
    }
  }
}

/// like an intersection type. An entity with many components, or a type that essentially just inherits the given types and adds no other members of its own.
/// Any type that extends anything will resolve as an entity, with the supertype being the first component of the entity. (Method inheritance is more complicated and not in yet.)
class EntityType extends TType {
  final List<TType> types;
  EntityType(this.types) : super();
  @override
  toCbor() {
    return CborMap({
      CborString("kind"): CborString("entity"),
      CborString("types"): CborList(types.map((t) => t.ref.toCbor()).toList()),
    });
  }

  @override
  void trace(Function(Obj p1) visitor) {
    for (final t in types) {
      visitor(t);
    }
  }

  @override
  friendlyName(StringBuffer out) {
    out.write('(intersection');
    for (final t in types) {
      out.write(' ');
      t.friendlyName(out);
    }
    out.write(')');
  }
}

// Usually implicit, any Obj that has a non-null `thunk` should be resolved as an entity with a Thunk component at the front.
class Thunk extends Obj {
  Thunk(BigInt thunk) : super(Std.thunkType) {
    this.thunk = thunk;
  }
  @override
  CborValue toCbor() {
    return CborBigInt(thunk!);
  }

  @override
  void trace(Function(Obj p1) visitor) {}
}

/// note, all objects render on the wire as entities, but usually in your code you wont need to access most of the components of the entity, so you wont represent them as an Entity Obj. But sometimes, you will. For instance, if you have a UI that takes an Any and you want to inspect all of its components.
/// this does mean that an Entity serializes different..... o__o I'm not sure how to deal with that
class Entity extends Obj {
  final List<Obj> components;
  Entity(EntityType super.type, this.components);
  @override
  CborValue toCbor() {
    throw UnimplementedError(
        'Entity.toCbor() should not be called. Entities are usually rendered separately by a method that makes sure it\'s not calling against an Entity');
  }

  @override
  void trace(Function(Obj p1) visitor) {
    for (final c in components) {
      visitor(c);
    }
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
      ? CborMap({
          CborString("name"): CborString(name),
          CborString("parameterName"): CborString(parameterName!),
          CborString("description"): CborString(description),
        })
      : CborMap({
          CborString("name"): CborString(name),
          CborString("type"): type!.ref.toCbor(),
          CborString("description"): CborString(description),
        });
  ParametricField(this.name, this.type, this.parameterName,
      {this.description = ""});
}

class ParametricStruct extends ParametricType {
  final List<ParametricField> structFields;
  ParametricStruct(super.definition, super.name, super.parameterRequirements,
      this.structFields);
  @override
  CborValue toCbor() {
    return CborMap({
      CborString("kind"): CborString("parametric_struct"),
      CborString("parameters"): CborList(parameterRequirements
          .map((p) => CborMap({
                CborString('name'): CborString(p.name),
                CborString('kind'): CborString(p.kind.toString()),
                CborString('type'): p.typeBound.ref.toCbor(),
              }))
          .toList()),
      CborString('fields'):
          CborList(structFields.map((f) => f.toCbor()).toList()),
      CborString("name"): CborString(name),
      CborString("definition"): cborNully(definition?.toCbor())
    });
  }

  @override
  void trace(Function(Obj p1) visitor) {
    // `definition` is non-necessary
    for (final r in parameterRequirements) {
      visitor(r.typeBound);
    }
    for (final f in structFields) {
      if (f.type != null) {
        visitor(f.type!);
      }
    }
  }
}

enum TypeParameterKind { instance, subtype }

class TypeParameter {
  final String name;
  final TType typeBound;
  // if Instance, this is an algebraic type and this parameter should be a constant value of type typeBound. Otherwise, Subtype, this parameter should be filled with a type that is a subtype of typeBound
  final TypeParameterKind kind;
  TypeParameter(this.typeBound, this.kind, this.name);
}

// These are really not types until you've parametized them. They're a *way of making* types once given the template parameters. ie, they're a bijective const function that takes types and (we're trying to be a dependent type system) vals and returns a type. They also tend to have a name, which they know themselves. But that can just be a Name trait that gets added in. So really this should just be a function
abstract class ParametricType extends Obj {
  final String name;
  // the code where it was defined.
  final Ref? definition;
  final List<TypeParameter> parameterRequirements;
  ParametricType(this.name, this.definition, this.parameterRequirements)
      : super(Std.parametizedTypeFunctionType);
}

class ParametizedType extends TType {
  final ParametricType pt;
  final List<Obj> parameters;
  ParametizedType(this.pt, this.parameters) : super();
  @override
  friendlyName(StringBuffer out) {
    out.write('(');
    out.write(pt.name);
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
    return CborMap({
      CborString("kind"): CborString("parametized_type"),
      CborString("function"): pt.ref.toCbor(),
      CborString("parameters"):
          CborList(parameters.map((o) => o.ref.toCbor()).toList()),
    });
  }

  @override
  void trace(Function(Obj p1) visitor) {
    visitor(pt);
    parameters.forEach(visitor);
  }
}

class IntrinsicParametricType extends ParametricType {
  final String intrinsicName;
  IntrinsicParametricType(this.intrinsicName, super.definition, super.name,
      super.parameterRequirements);
  @override
  CborValue toCbor() {
    return CborMap({
      CborString("kind"): CborString("intrinsic"),
      CborString("intrinsic_name"): CborString(intrinsicName),
      CborString("parameters"): CborList(parameterRequirements
          .map((p) => CborMap({
                CborString("name"): CborString(p.name),
                CborString("kind"): CborString(p.kind.toString()),
                CborString("type"): p.typeBound.ref.toCbor(),
              }))
          .toList()),
      CborString("definition"): cborNully(definition?.toCbor())
    });
  }

  @override
  void trace(Function(Obj p1) visitor) {
    for (final p in parameterRequirements) {
      visitor(p.typeBound);
    }
  }
}

class Std {
  static final BasicType typeType = (() {
    var tt = BasicType.withoutType(BasicTypeTag.typeType);
    tt.type = tt;
    return tt;
  })();
  static final BasicType boolType = BasicType(BasicTypeTag.boolType);
  static final BasicType intType = BasicType(BasicTypeTag.intType);
  static final BasicType stringType = BasicType(BasicTypeTag.stringType);
  static final BasicType anyType = BasicType(BasicTypeTag.anyType);
  static final BasicType blobType = BasicType(BasicTypeTag.blobType);
  static final BasicType thunkType = BasicType(BasicTypeTag.thunkType);
  static final fileType = NamedType(
      "file",
      null,
      StructType([
        FieldInfo(name: "name", type: stringType),
        FieldInfo(name: "content", type: blobType)
      ], null));
  // generics are mostly just a reversible const function that returns types and has a static name getter. But we aren't going to use the function type and `statically named` trait to define them because I can't be bothered with that yet.
  // (A reversible function is a function which, given its own outputs, can give you the inputs that made it. It's necessary for generics to be reversible because that's the requirement for type inference)
  static final BasicType parametizedTypeFunctionType =
      BasicType(BasicTypeTag.parametricType);
  static final BasicType dateTime = BasicType(BasicTypeTag.dateTime);
  // ParametricStruct slotEventParametricType = ((){

  // })();
  static final IntrinsicParametricType vecParametricType = (() {
    return IntrinsicParametricType("vec", null, "vec",
        [TypeParameter(anyType, TypeParameterKind.subtype, "T")]);
  })();
  static final IntrinsicParametricType slotParametricType = (() {
    return IntrinsicParametricType("slot", null, "slot",
        [TypeParameter(anyType, TypeParameterKind.subtype, "T")]);
  })();
  static final ParametizedType vecAny =
      ParametizedType(vecParametricType, [anyType]);
  static final TType burlType = (() {
    // hmm, now would be a good time for an alias type. A burl should just be a vec, right?
    return NamedType("burl", null,
        StructType([FieldInfo(name: "contents", type: vecAny)], null));
  })();
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
  IntObj(this.value) : super(Std.intType);
  @override
  CborValue toCbor() => CborInt(BigInt.from(value));
  @override
  void trace(Function(Obj p1) visitor) {}
}

class StringObj extends Obj {
  String value;
  StringObj(this.value) : super(Std.stringType);
  @override
  CborValue toCbor() => CborString(value);
  @override
  void trace(Function(Obj p1) visitor) {}
}

class BoolObj extends Obj {
  bool value;
  BoolObj(this.value) : super(Std.boolType);
  // string encoding required by IPLD
  @override
  CborValue toCbor() => CborString(value ? "true" : "false");
  @override
  void trace(Function(Obj p1) visitor) {}
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

List<(CID, Uint8List)> makeCommit(Obj obj) {
  return makeCommitAll([obj]);
}

/// asigns refs to all of the objects linked from roots that lack them, returns a list of the new objects
/// ensures that none of the blobs end up with identical refs by adding a thunk component to the ones that clash
/// (another counterintuitive thing it does is it assigns temporary same_burl ids to items within a burl while the items of that burl are being serialized (before toCbor is called) so that toCbor will resolve local links when appropriate. Anyone implementing a toCbor method (everyone) might like to know this, but I really can't foresee a situation where they'd *need* to.)
List<(CID, Uint8List)> makeCommitAll(List<Obj> roots) {
  // the objects currently being fingered by the depth first search
  // todo: make sure you assigned the null thunk to all of the objects that didn't need one.
  List<Obj> stack = [];
  List<Obj> allVisited = [];
  HashMap<Obj, Burl> burlAssignments = HashMap<Obj, Burl>();
  HashSet<Obj> visited = HashSet<Obj>();
  HashSet<Obj> stacked = HashSet<Obj>();

  // optimization todo: use the refs to encode visited state intrusively
  // bool visited(Obj o) => o._ref != null;
  // bool resolved(Obj o) => o._ref != null && o._ref != const Ref.empty && o._ref.segments[0]!.kind != OPSegmentKind.indexing;
  // bool stacked(Obj o) => o._ref != null && o._ref != const Ref.empty && o._ref.segments[0]!.kind == OPSegmentKind.indexing;

  // consists of a depth first search that reacts when we hit something that's in the current stack (this is how you find cycles)
  void visit(Obj v) {
    if (v._ref != null) {
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
      v.trace(visit);
    }
    stacked.remove(v);
    stack.removeLast();
  }

  //it starts by doing a pass to figure out what needs to be in burls
  for (Obj r in roots) {
    visit(r);
  }
  HashSet<CID> idsSoFar = HashSet<CID>();

  // reify the ids
  // those with no dependencies will be at the beginning, the last root node will be at the end
  List<Burl> populatedBurls = [];
  List<(CID, Uint8List)> ret = [];
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
      if (b._ref == null) {
        //resolve everything in the burl, otherwise, nothing needs to be done, this obj is already resolved

        // temporarily assign same_burl ids so that when this object is referenced in a serialization by the following toCbor calls, it is a local link
        for (int bi = 0; bi < b.content.length; ++bi) {
          b.content[bi].assignID(Ref.sameBurl(bi));
        }

        CborValue cburl = b.toCbor();

        // this could be violated if burl format changes
        Uint8List burlBinary = cborBinary(cburl);
        CID burlID = cborID(burlBinary);
        while (idsSoFar.contains(burlID)) {
          // create thunk
          final thunk = Random.secure().nextInt(1);
          // reserialize
        }
        b.assignID(Ref(burlID));
        ret.add((burlID, burlBinary));
        for (int boi = 0; boi < b.content.length; ++boi) {
          final id = Ref.intoBurl(burlID, boi);
          assignID(b.content[boi], id);
        }
      }
    } else {
      //isn't in a burl
      final b = cborBinary(o.toCbor());
      final id = cborID(b);
      assignID(o, Ref(id));
      ret.add((id, b));
    }
  }

  return ret;
}

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

enum BasicTypeTag {
  boolType,
  intType,
  stringType,
  anyType,
  typeType,
  parametricType,
  dateTime,
  blobType,
  thunkType; //I don't think this should be a basic type.

  TType get type {
    switch (this) {
      case BasicTypeTag.boolType:
        return Std.boolType;
      case BasicTypeTag.intType:
        return Std.intType;
      case BasicTypeTag.stringType:
        return Std.stringType;
      case BasicTypeTag.anyType:
        return Std.anyType;
      case BasicTypeTag.typeType:
        return Std.typeType;
      case BasicTypeTag.parametricType:
        return Std.parametizedTypeFunctionType;
      case BasicTypeTag.dateTime:
        return Std.dateTime;
      case BasicTypeTag.blobType:
        return Std.blobType;
      case BasicTypeTag.thunkType:
        return Std.thunkType;
    }
  }

  String get name {
    switch (this) {
      case BasicTypeTag.boolType:
        return 'bool';
      case BasicTypeTag.intType:
        return 'int';
      case BasicTypeTag.stringType:
        return 'string';
      case BasicTypeTag.anyType:
        return 'any';
      case BasicTypeTag.typeType:
        return 'type';
      case BasicTypeTag.parametricType:
        return 'parametric_type';
      case BasicTypeTag.dateTime:
        return 'date_time';
      case BasicTypeTag.blobType:
        return 'blob';
      case BasicTypeTag.thunkType:
        return 'thunk';
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
