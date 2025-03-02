// planning on writing an algorithm that does bfs from each definite item in each disjoint graph then reports if there's an error. Disjoint graphs need not block each other from being checked.
// but I need to think about where to report the error. When two requirements disagree, where do we point? Do we just point to both/all user-specified items involved? No, we also hae to point at the place where they collide or else the user will be very cofused... and also all of the places where the types propagated.

import 'dart:collection';
import 'package:set_list/set_list.dart';


/* example of the type of structure this would need to deal with
let a = 2
let b = 2.5
var c = a
c = b
c = "gammo"
return c
->
  num = a < c
  float = b < c
  String < c
  c < return

let a: String = "gammo"
let b: bool = a
->
  String = a > String
  bool = b > a

let a;
let doggal = <T: Add<int>>(a: T) => a + 2;
let f = (a)=> doggal(a)
a = f(1)
let b = a
->
  a > f.input > doggal.inputBound.T
  b < a
  f.invocation.input.T < int
*/

TypeKnows{
  // if it lacks any type in this set, it's a type error
  subset: List<Requirement>
  // if it has any type outside of this set, it's a type error
  // null means anything is allowed/infinite set
  superset: List<Requirement>?
  // if it's a value rather than a type, it's here
  value: Obj?
  has: List<Requirement>
}
void testSubType(a: TypeKnows, b: TypeKnows){
  errors: b.has.difference(a.has).map { r in TypeCheckError(r, a, b) }
}
void testSuperType(a: TypeKnows, b: TypeKnows){
  errors: a.has.difference(b.has).map { r in TypeCheckError(r, a, b) }
}
void propagateRequirements(a: TypeKnows, b: TypeKnows, relation: RelationType){
  switch relation {
    case .subtype:
      // ... it just occurred to me that type inference for dependent types needs a very general solver, so I'm not sure I should implement this. Considering Spritely Brainy.
      // well I looked at it and it seems understandable enough. For our purposes I don't think we need that. We'll see.
      
      // might want to use comparisonScan
      break
    case .supertype:
      testSuperType(a, b)
    case .equal:
      testEqual(a, b)
  }
}



class SolutionState<K, V> {
  K key;
  bool definite = false;
  List<V> requirements;
  // greater than or equal to
  List<SolutionState<K, V>> supersets = [];
  // less than or equal to
  List<SolutionState<K, V>> subsets = [];
  SolutionState(this.key, this.requirements);
}

class ToSolve<K, V> {
  final K key;
  final List<V> requirements;
  ToSolve(this.key, this.requirements);
}

enum RelationType { subset, superset, equal }

class Relation<K, V> {
  final K from;
  final K to;
  final RelationType type;
  Relation(this.from, this.to, this.type);
}

class Error {
  final String message;
  Error(this.message);
}

class SolverOutput<K, V> {
  List<Error> errors = [];
  HashMap<K, SolutionState<K, V>> solutions = HashMap();
  bool get isConsistent => errors.isEmpty;
  SolverOutput(List<ToSolve<K, V>> subjects, List<Relation<K, V>> relations) {
    for (var subject in subjects) {
      solutions[subject.key] =
          SolutionState<K, V>(subject.key, subject.requirements);
    }
    for (var relation in relations) {
      solutions[relation.from]!.supersets.add(solutions[relation.to]!);
    }
  }
}
