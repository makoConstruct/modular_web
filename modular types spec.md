## modular types spec


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



# V2

This is a draft for now.

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