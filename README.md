Basics for working with the mw distributed typed object system. Identity, permissioning, parsing, binding generation, syncing, rpc, pubsub.


## about modular types

- A composable, cross-language type system and encoding for data and API signatures. A language of languages for social computing.
- A __downcast__ operation that allows modular objects to be extended by anyone with additional fields without ever breaking other peoples' code.
- An __upcast__ operation/__Any__ type that allows, eg, arbitrary objects to be attached to posts in user-extensible web apps with enough type information for the computer to automatically fetch a viewer/editor that the community recommends for that object in that context.
- Modular types was made for [modular web], but it's intended for general use in all languages and frameworks whenever they need to communicate over the network.
- modular types are referenced with content-addresses, which essentially means anyone can create a type, and if others use it, the type definition will stay available forever, while also guaranteeing that components of a type will never have id or member name collisions.
- To achieve this, we've expanded on the standard IPLD format by introducing a way of representing self-referential structures, which types often require. Cyclic structure is also sometimes needed for [serialisation of object graphs](https://whtwnd.com/did:plc:2mfp3fiamge4hp6s5xmki7vm/entries/Self-referential%2Fcyclic%20structure%20is%20both%20necessary%20and%20possible%20in%20content-addressed%20protocols%2C%20but...) in high level applications.
- type system features:
    - Inheritance
    - Parametric types
        - variance (eg, `List<int>` subtypes `List<num>`, while `Function<num>` subtypes `Function<int>`)
        - non-type inputs ("dependent types") eg: for stating a matrix's dimensions as part of its type.
        - With a variable number of inputs ("variadic").
    - Intersection types
    - Sum types (discriminated unions/case classes/enums)
- This type system is quite sophisticated/complex, but if you're working in a language or style that can't handle that kind of type complexity, the binding generators will get it out of the way, because type checks can (and usually need to) be done at runtime, so your language doesn't need to understand the types to benefit here. Indeed, currently, no widely used programming language supports all of the features of the type system, but it seems so far that this is fine, binding generators/codegen/macros have always been able to represent the data pretty smoothly in the host language.
