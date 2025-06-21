## Efficient representation for dynamically castable objects

the following code implements dynamic upcasting and downcasting over objects with runtime type information in an efficient way. It represents objects mainly as two arrays, where upcasts (and upcasts of upcasts and so on) are just a binary search, and downcasts are just a binary search and a few traversals up the component tree.

The `components` array is the inheritance heirarchy flattened to pre-order. Each entry has the value of the component, its total number of descendents, and the index of its parent component (used in downcasting).

The other array is `map`, which is a sorted array of (type, k) tuples, mapping the type of a component to its index in `components` (its pre-order index).

This wouldn't be much use if you needed to mutate this structure, but you basically never do, it's type information.

This is essentially an associative array between Types and values, but where the get operation can be given a range of pre-order indices to restrict the search to, and that's how you restrict the search to a particular subcomponent, which is a necessary capability for repeated upcasting (*ie, accessing a component inside a component*) and for correct downcasting (whcih has to be the reverse operation). (*Although I admit I'm having trouble thinking of a situation where someone would care very much about downcasting correctness, it could also be done by simply upcasting from the object root... honestly I feel like that's closer to what people expect. Comments needed.*)

This also to a large extent supports casting to generics with variance. Since the parameters in the component's `Type` sometimes don't need to be an exact match for the component to still match the search type (EG, an object that has a `List<Integer>` component should be castable to `List<Number>`, since `Number` is a supertype of `Integer`), only a binary search structure will do. However, it wont be fully logarithmic, if there are a lot of generic type components, there'll be a component of the search that's linear, since the parameters of these types don't have an ordering that corresponds to the subtyping relation. I'm ultimately not very excited about implementing generic variance tbh.

Note, in the wild, much of this structure would be kept in the type of the object, not the object itself, as it doesn't vary at runtime. Within the objects would mainly just be something like the `components` array, but without the total_descendent_count and parent_index fields. A static type system wouldn't necessarily need this kind of optimization, since the upcasting offset is calculated at compile time and constant-time at runtime.