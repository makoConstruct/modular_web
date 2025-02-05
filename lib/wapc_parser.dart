import 'dart:collection';

import 'package:woodslist/woodslist.dart';
import 'package:modular_web/modular_web.dart';

// wapc is a woodslist format that represents APC types. Apc types for checking and stuff are encoded using the wire format (ApcTypeDef extends Object), but we can write them with text using wapc.

String dartFileForTTypes(List<TType> apc) {
  return throw UnimplementedError();
}

/*

*/

class ParseError extends Error {
  final String message;
  final List<Wood> locations;
  ParseError(this.message, this.locations);
}

Branch assertBranch(Wood w) {
  if (w is! Branch) {
    throw ParseError('class must be a branch', [w]);
  }
  return w;
}

Wood assertGet(Wood b, int i, {String? message}) {
  if (i >= (b as Branch).v.length) {
    throw ParseError(
        message ?? 'branch should have at least ${i + 1} elements', [b]);
  }
  return b.v[i];
}

Wood? maybeGet(Branch b, int i) {
  if (i >= b.v.length) {
    return null;
  }
  return b.v[i];
}

class HandleCell {
  final String name;
  // there should be only one, but if there's more than one, we register that for error reporting.
  final List<Wood> mentions = [];
  final List<Wood> definitions = [];
  final Scope scope;
  late final Obj? value;
  late final void Function(Obj self) complete;
  HandleCell(this.scope, {required this.name});
}

class Scope {
  final HashMap<String, HandleCell> names = HashMap();
  final Scope? parent;
  List<Scope> childScopes = [];
  List<HandleCell> typeDefinitions = [];
  Scope({this.parent});
  Scope nestedScope() {
    Scope ns = Scope(parent: this);
    childScopes.add(ns);
    return ns;
  }

  HandleCell? getHandle(String name) {
    return names[name] ?? (parent?.getHandle(name));
  }

  HandleCell getOrCreateHandle(String name) {
    HandleCell? h = getHandle(name);
    if (h == null) {
      h = HandleCell(this, name: name);
      names[name] = h;
    }
    return h;
  }

  HandleCell registerMention(String name, Wood mention) {
    return getOrCreateHandle(name)..mentions.add(mention);
  }

  HandleCell registerDefinition(String name, Wood definition,
      {bool isType = false}) {
    final ret = getOrCreateHandle(name)..definitions.add(definition);
    if (isType) {
      typeDefinitions.add(ret);
    }
    return ret;
  }

  List<HandleCell> registerTypeParameters(Wood w) {
    HandleCell hc;
    // this is wrong, you parsed them as if they were the inputs, they're the parameter declarations
    if (w is Branch) {
      Wood term =
          assertGet(w, 0, message: "an empty branch here is meaningless");
      for (int ii = 1; ii < w.v.length; ++ii) {
        registerTypeParameters(ww);
      }
    } else {
      String token = w.initialStr();
      registerMention(token, w);
    }
  }
}

/// throws `List<ParseError>`
/// returns TTypes and ParametricTypes, all named.
List<Obj> parseWapc<T>(FileObj file) {
  List<ParseError> errors = [];
  RT? errorCaptureScope<RT>(RT Function() f) {
    try {
      return f();
    } catch (e) {
      if (e is ParseError) {
        errors.add(e);
        return null;
      } else {
        rethrow;
      }
    }
  }

  String fileString = file.stringContent();
  Wood fw = parseMultipleWoodslist(fileString);
  // translate to Objs
  List<TType> ret = [];

  // [current status] I'm going to rewrite all of this such that handlelcells all contain Objs with unset late members, and there's a `complete` function that resolves them all once we've located all of the definitions.
  // Current roadblock: If paramemtric types can have complex structures, how do they refer to their parameters?

  // allows referring to objects before they've been defined

  Scope rootScope = Scope();
  Scope scope = rootScope;

  void enterScope(void Function() f) {
    Scope oldScope = scope;
    scope = scope.nestedScope();
    try {
      f();
    } finally {
      scope = oldScope;
    }
  }

  void scanVar(Wood w, {required int offset}) {
    Branch bw = assertBranch(w);
    if (bw.v.length - offset < 1) {
      throw ParseError(
          'var declarations must provide a name for the var', [bw]);
    }
    if (bw.v.length - offset > 1) {
      scope.registerTypeParameters(bw.v[offset]);
      scope.registerDefinition(assertGet(bw, offset + 1).initialStr(), bw);
    } else {
      scope.registerDefinition(assertGet(bw, offset).initialStr(), bw);
    }
  }

  void scanClass(Branch bw, {bool parametric = false}) {
    errorCaptureScope(() {
      enterScope(() {
        int i;
        HandleCell hc;
        if (parametric) {
          i = 2;
          Branch parameters = assertBranch(assertGet(bw, i++,
              message:
                  "parametric class should have name and parameters at the end of this branch"));
          String name = parameters.initialStr();
          if (name == '') {
            throw ParseError('parametric class must have a name', [bw]);
          }
          hc = scope.registerDefinition(name, bw, isType: true);
          if (parameters.v.length < 2) {
            throw ParseError(
                'parametric class must have at least one parameter', [bw]);
          }
          for (int ii = 1; ii < parameters.v.length; ++ii) {
            scope.registerTypeParameters(parameters.v[ii]);
          }
        } else {
          i = 1;
          hc = scope.registerDefinition(
              assertGet(bw, i++, message: "a class should have a name")
                  .initialStr(),
              bw,
              isType: true);
        }

        Wood? curw = maybeGet(bw, i++);
        List<HandleCell> extendTypes = [];
        if (curw == null) {
          return;
        } else if (curw.initialStr() == 'extends') {
          Branch ceb = assertBranch(curw);
          for (int ci = 1; ci < ceb.v.length; ++ci) {
            extendTypes.add(scope.registerTypeParameters(assertGet(ceb, ci)));
          }
          curw = maybeGet(bw, i++);
        }
        while (curw != null) {
          String op = curw.initialStr();
          switch (op) {
            case 'var':
              {
                scanVar(curw, offset: 1);
              }
          }
        }

        TType named(Obj o) => NamedType(name, file.ref, o);
        if (parametric) {
          // this is the point where you really need to come to a resolution about object identity/thunking
          if (extendTypes.isNotEmpty) {
            hc.value = named(Entity([structo] + extendTypes));
          } else {
            hc.value = named(structo);
          }
        } else {
          StructType structo = StructType(definition: file.ref);
          if (extendTypes.isNotEmpty) {
            hc.value = named(Entity(<TType>[structo] +
                extendTypes.map((e) => e.value as TType).toList()));
          } else {
            hc.value = named(structo);
          }
        }
      });
    });
  }

  void scanEnum(Branch bw, {bool parametric = false}) {
    errorCaptureScope(() {
      enterScope(() {
        int i;
        if (parametric) {
          i = 2;
          Branch parameters = assertBranch(assertGet(bw, i++,
              message:
                  "parametric enum should have name and parameters at the end of this branch"));
          String name = parameters.initialStr();
          if (name == '') {
            throw ParseError('parametric enum must have a name', [bw]);
          }
          scope.registerDefinition(name, bw, isType: true);
          if (parameters.v.length < 2) {
            throw ParseError(
                'parametric enum must have at least one parameter', [bw]);
          }
          for (int ii = 1; ii < parameters.v.length; ++ii) {
            scope.registerTypeParameters(parameters.v[ii]);
          }
        } else {
          i = 1;
          scope.registerDefinition(
              assertGet(bw, i++, message: "an enum should have a name")
                  .initialStr(),
              bw,
              isType: true);
        }
        Wood? curw = maybeGet(bw, i++);
        while (curw != null) {
          String op = curw.initialStr();
          switch (op) {
            case 'var':
              {
                scanVar(curw, offset: 1);
              }
            case 'variant':
              {
                int i = 1;
                String name = assertGet(curw, i++).initialStr();
                if (name == '') {
                  throw ParseError('variant must have a name', [curw]);
                }
                scope.registerDefinition(name, curw, isType: true);
                Wood? nw = maybeGet(bw, i++);
                while (nw != null) {
                  scanVar(nw, offset: 0);
                  nw = maybeGet(bw, i++);
                }
              }
          }
          curw = maybeGet(bw, i++);
        }
      });
    });
  }

  // first do a pass where we check syntax, identify and relate all of the mentions and definitions, create the connective structure, and make sure everything mentioned has exactly one definition.
  for (Wood w in (fw as Branch).v) {
    switch (w.initialStr()) {
      case 'class':
        {
          scanClass(assertBranch(w), parametric: false);
        }
      case 'enum':
        {
          scanEnum(assertBranch(w), parametric: false);
        }
      case 'parametric':
        {
          Branch bw = assertBranch(w);
          String kind = assertGet(bw, 1).initialStr();
          switch (kind) {
            case 'class':
              {
                scanClass(bw, parametric: true);
              }
            case 'enum':
              {
                scanEnum(bw, parametric: true);
              }
          }
        }
    }
  }

  // make sure the numbers are correct

  for (MapEntry<String, HandleCell> h in scope.names.entries) {
    if (h.value.definitions.isEmpty) {
      errors.add(ParseError(
          'there are no definitions for "${h.key}"', h.value.mentions));
    } else if (h.value.definitions.length > 1) {
      errors.add(ParseError(
          'there are multiple definitions for ${h.key}', h.value.definitions));
    }
  }
  if (errors.isNotEmpty) {
    throw errors;
  }

  // then do a pass where we finalize the types.
  // decided to go over them in the same order they were encountered in the file just for the heck of it.
  // this wont work, context matters, enum variant types can't be defined without additional context
  for (HandleCell h in rootScope.typeDefinitions) {
    Wood d = h.definitions.single;
  }

  // maybe don't do it this way since you'll lose the nested scopes
  // similar structure to the above, with many checks removed, as they've already been done and passed
  // void encodeClass(Branch bw, {bool parametric = false}) {
  //   errorCaptureScope(() {
  //     enterScope(() {
  //       int i;
  //       if (parametric) {
  //         i = 2;
  //         Branch parameters = assertBranch(assertGet(bw, i++));
  //         String name = parameters.initialStr();
  //         scope.registerDefinition(name, bw);
  //         for (int ii = 1; ii < parameters.v.length; ++ii) {
  //           scope.registerTypeParameters(parameters.v[ii]);
  //         }
  //       } else {
  //         i = 1;
  //         scope.registerDefinition(
  //             assertGet(bw, i++, message: "a class should have a name")
  //                 .initialStr(),
  //             bw);
  //       }

  //       Wood? curw = maybeGet(bw, i++);
  //       if (curw == null) {
  //         return;
  //       } else if (curw.initialStr() == 'extends') {
  //         Branch ceb = assertBranch(curw);
  //         for (int ci = 1; ci < ceb.v.length; ++ci) {
  //           scope.registerTypeParameters(assertGet(ceb, ci++));
  //         }
  //         curw = maybeGet(bw, i++);
  //       }
  //       while (curw != null) {
  //         String op = curw.initialStr();
  //         switch (op) {
  //           case 'var':
  //             {
  //               scanVar(curw, offset: 1);
  //             }
  //         }
  //       }
  //     });
  //   });
  // }

  // // then do a pass where we finalize the types.
  // for (Wood w in fw.v) {
  //   switch (w.initialStr()) {
  //     case 'class':
  //       {
  //         encodeClass(assertBranch(w), parametric: false);
  //       }
  //     case 'enum':
  //       {
  //         scanEnum(assertBranch(w), parametric: false);
  //       }
  //     case 'parametric':
  //       {
  //         Branch bw = assertBranch(w);
  //         String kind = assertGet(bw, 1).initialStr();
  //         switch (kind) {
  //           case 'class':
  //             {
  //               encodeClass(bw, parametric: true);
  //             }
  //           case 'enum':
  //             {
  //               scanEnum(bw, parametric: true);
  //             }
  //         }
  //       }
  //   }
  // }

  return ret;
}
