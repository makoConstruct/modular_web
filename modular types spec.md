## modular types spec

People who should read this:

- People who have spoken to mako and are doing a port from the reference implementation. It's important to speak to an architect first, so that we can guide you through the most efficient way of doing it.

- People who are trying to optimize the performance of a port.

- People who want to propose adding a new feature to the protocol.

People who should not read this:

- People who are trying to learn how the protocol generally works and appraise its quality.

Reading the spec is a terrible way of getting to know the protocol.

Learning about a protocol by reading the spec is like learning a language by reading a dictionary.

The spec is a long list of low-level details that are mostly abstracted away in the user experience. The spec looks and feels nothing like using the thing. The best way to understand the protocol is to read the overview. I have not written the overview yet though sorry.

## enums

Enums could be thought of as a syntactical sugar that maps like this:

```
enum Code {
  var author: Author
  Code(this.author) {}
  variant Function {
    params: List<Let>
    Function(this.params, author: Author): Code(author) {}
  }
  variant Block {
    params:   List<Let>
    Block(this.params, author: Author): Code(author) {}
  }
  variant Evaluation {
    function: Function
    args: List<Obj>
    Evaluation(this.function, this.args, author: Author): Code(author) {}
  }
}

->

abstract sealed class Code {
  var author: Author
  var discriminant: Int
  Code(this.author, this.discriminant) {}
}

class Function extends Code {
  List<Let> params;
  Function(this.params, author: Author): super(author, 0) {}
}

class Block extends Code {
  List<Let> params;
  Block(this.params, author: Author): super(author, 1) {}
}

class Evaluation extends Code {
  Function function;
  List<Obj> args;
  Evaluation(this.function, this.args, author: Author): super(author, 2) {}
}

->

class FunctionT implements Code {
    Author get author => component[types.codeType];
    late final List<Let> params;
    late final Block body;
    FunctionT(Author author,this.params?, this.body?): super(author, 0, type: types.functionT) {
        if(params == null) {
            params = [];
        }
        if(body == null) {
            body = Block(author, []);
        }
    }
    FunctionT Function() parse() {
        
    }
}
```

With the additional rule that a limited, specified set of classes are allowed to extend the Enum inheritor directly (It's like a sealed class)

Why a discriminant? Although you can usually discriminate using the Obj's `type`, that wont work for `raw` objs. We like having an enum type that works for `raw` Objs. We might add `sealed class` later if you really really don't want to have a discriminant in your dynamic Objs (why??..).

## Encoding

We're currently using dag-cbor.

Here's an example of things being encoded:

`Let(type: Int) & Name("credit")` (a let statement of type Int, with the name "credit"):

```
[
   [#Let [#Int] [#[[#Code [0]]]]]
   [#Name [[#String ["credit"]]]]
]
```

Where #<name> is a `Ref` to a type and #<expr> indicates that the object is on the other side of a ref.

What's a `Ref`? All links between objects are encoded as `Ref`s in modular v0. Refs are paths through content-addressed objects, usually containing just one element, the content-address of an object.

```
[[0 #a873b920c]]
```

Each segment of a Ref path (each "OPSegment") is premised with its kind, an integer.

```
enum OPSegment {
  cid(discriminator = 0, Hash)
  parent(discriminator = 1, void)
  indexing(discriminator = 2, Int)
}
```

the `cid` variant just identifies an object with its IPLD Content ID [todo: be more specific]. In contrast, the `parent` variant refers to the parent of the current object, usually to be followed by an `indexing` variant that says which sibling the path is referring to.

Sibling (or Self) refs are needed whenever there's a cycle in the object graph. Usually these objects are children of a `Burl`.

Let's present a more complex example that demonstrates a cycle.

It consists of a definition of a type, "Brother", and then two Brother instances who refer to each other.

```
struct Brother {
    other_brother: Brother
}

let mario = Brother {
    other_brother: luigi
} & Name("mario")
let luigi = Brother {
    other_brother: mario
} & Name("luigi")
```

```
#Brother = #[
    [#Name
        [#[[#String "Brother"]]]]
    [#Struct [
        #[[#[[#Parametization [#List [#Let]]]] [
            #[
                [#Let #Brother [#[[#Code [0]]]]]
                [#Name #[[#String "other_brother"]]]
            ]
        ]]]
    ] [#[[#Code [3]]]]]
]

#mario = #[[#Brother [#luigi]] [#Name [#[[#String "mario"]]]]]
#luigi = #[[#Brother [#mario]] [#Name [#[[#String "luigi"]]]]]
```

You'll notice we don't use Cbor Maps, this is because dag-cbor forbids anything other than strings as object keys, but we use Refs in keys and are proud of it because refs are globally unique and self-describing. If the decreased wire efficiency imputed by dag-cbor bothers you, don't worry, we'll probably abandon the dag-cbor encoding one day.

But notice that there's a cycle here. This isn't quite a real encoding yet. Let's finish it off.

```
#Brother = [
    [#Name
        [#[[#String "Brother"]]]]
    [#Struct [
        #[[#[[#Parametization [#List [#Let]]]] [
            #[
                [#Let #Brother [#[[#Code [0]]]]]
                [#Name #[[#String "other_brother"]]]
            ]
        ]]]
    ] [#[[#Code [3]]]]]
]

#burl = #[[#Burl [
    #[[#Brother [#luigi]] [#Name [#[[#String "mario"]]]]]
    #[[#Brother [#mario]] [#Name [#[[#String "luigi"]]]]]
]]]
```

The other_brother refs start with a parent segment, then there's an indexing segment that refers to the other object in the burl.

So, when we commit these three objects (Brother, Mario, Luigi), we publish two content-addressed objects, Brother, and a burl containing Mario and Luigi. The reason Brother doesn't have to be in the burl is that it isn't involved in any cycles, so it can be distributed independently.

Please note the `#Type` and `#Code` components. They're there because every Type is a variant in the Code enum, so they inherit Code. Extended types go after the data listing.

well this didn't end up being relevant to the questions I've been minding, but I guess those questions are maybe trivial. Oh I kind of answered how we do generic keys. Not sure I like the answer though.

New crisis: What if the sort order of sorted components... fails to capture the order of component precedence?.. hmm, that's up tho the bindings. It's about how bound objects store the interface.



## Deprecating fields

No type defined in modular ever changes, so how do you talk about deprecations? Here's how, it's pretty neat.

When we want to communicate that an object has deprecated fields — or more formally, deprecasted components — we use the `Deprecation` type. Here's the Deprecation type in its entirety:

```javascript
  class Deprecation<Favor, Disfavor: ...Type, notice:DeprecationNotice> extends Favoring, ...Disfavoring {}
  
  class DeprecationNotice {
    message: String,
    deadline: DateTime?
  }
```

So, deprecation types are essentially just an intersection of both the new type and the old types, plus a notice. For the machines that can't immediately switch away from the types being disfavored, the Deprecation type will just keep working as if it were still the old types. For machines that are paying attention, the Deprecation type will also provide the new type (`Favor`) and a `notice` that explains why we're switching to `Favor` and an option al Date `deadline` that says when the we'll drop the disfavored types from this value.
example of usage:
```javascript
  // from the old library:
  class Member {
     name: String,
     favouriteColor: Color,
  }
  
  // the new library
  class Member {
    name: String,
  }
  class MemberDeprecation: Deprecation<Member, old_version.Member, notice: DeprecationNotice(message: "We're removing the favouriteColor field. Fashion has progressed. Adults should be expected to, and certainly allowed to transcend all attachment to color.", deadline: None)
  
  class API<Member: Member> {
    void registerMember(Member v)
  }
  
  expose API<MemberDeprecation>
```
Why is `notice` a type parameter? A piece of data should be part of the type rather than part of the instances __exactly when__ it's the known to the programmer at compile-time, ie, when we know every instance of this type will have the same value for that field.

When every instance has the same notice, it's more efficient to avoid repeating it in every deprecation object. Because we do it this way, the notice will take up literally zero bytes per object. Which sounds miraculous, doesn't it? It will be transmitted in the type information of the object, which does take up one or two bytes per object, but it was a byte we were already paying.




# V2

This is a draft for now.

## towards more concise binary encodings

We're not really getting much out of being dag-cbor, it was used in v1 just because optimizing binary size isn't interesting or important at all. But it's something we'd like to do later on once we can afford to.

- Allow types to describe arbitrary binary encodings?

- Use a pair type for ref segments instead of a list.

## raw and acyclic

When defining types, there are some implicit parameters that they take in from their surrounding scope

- `raw` (defaults to false) when true, denotes types that runtime type tags and can't have unexpected type components. Used when efficient packing and parsing is needed and extensibility isn't needed, for instance, when transmitting `List<f32>`s.
    - `deepRaw` is a subtype of `raw` that also constrains all of the members of the type component.
- `acyclic` (defaults to false) when true, denotes types whose objects don't take part in any cycles. Note that an acyclic type may refer to cyclic types.
    - `deepAcyclic` is as above.
- `monoref` (defaults to false) when true, denotes types that can only have one reference to them at a time.
    - `deepMonoref` also exists.

Turning on both `deepRaw` and `deepAcyclic` is generally necessary for smooth integration with Rust. Rust objects are always raw (no runtime type info), and it generally doesn't like dealing with cycles.

```
(with acyclic true (struct Manager
    (var subordinates (List Manager))
    (var title Title)
))

```
`with` is esssentially just a scope that sets an implicit parameter within its body, then returns it to its previous value after.

In this example, what we've done is we've imposed a type level constraint that the structure formed by the `Managar`ial directed hypergraph must be a dag, by turning the acyclic implicit to true within the scope of the definition of the `Manager` type.

Note that `Title` isn't defined within the `with` scope, so it might contain cycles. For that, you would need `deepAcyclic`.

If we also `(with monoref true)`, then that would constrain the structure to be a tree.

We think it's quite extraordinary that such things can be expressed on the type level, but types are ultimately just claims about data.

I'm unsure how to implement deep parameter requirements though. I notice that a Trace trait with a covariant bound might be able to do it.
```
class Trace<+T> {
    fn members(self)-> Iter<T>
}
```
If you implement `Trace<Raw>`, then that essentially communicates that you only contain `Raw` objects.



## TypeSpec

(speculative)

In many situations, the recipient of an object doesn't need the complete type information, and only needs enough to recognize the components of the type to dismiss it or to determine whether any of its inherited components are relevant. If we decide that's a good idea, we will introduce TypeSpecs and use those as component tags rather than the type ref.

A typespec generally consists of, for a unary type, the type ref, and for a parametric type, the type ref and the parameters.


## Cache control

Not all objects should be cached: Those that we can guarantee wont be referred to by remote parties.