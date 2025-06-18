use std::io::Bytes;


/// the following code illustrates how to represent modular objects in an extremely efficient way, consisting ultimately of just two arrays, where upcasts (of upcasts) are just a binary search.
/// in summary: the component tree is flattened to pre-order. The component map is stored as a sorted array of (key, index, value) tuples. When you're narrowed in on a particular subcomponent, you can still look up a subcomponent of that subcomponent in logarithmic time from the root map of the object by restricting answers to not just (key, _, _) but (key, i, _) .. (key, i + c, _) where i is the index of the subcomponent parent and c is the number of children of the parent.
/// obviously this isn't very good if you need to mutate the object, but generally states are represented as immutable objects.

pub struct Tree<K, V> {
    k: K,
    v: V,
    children: Vec<Tree<K, V>>,
}

pub struct ComponentMap<K, V> {
    map: Vec<(K, usize, V)>,
}

impl<K, V> ComponentMap<K, V> {
    fn recurse_tree(mut index: usize, tree: &Tree<K, V>, map: &mut ComponentMap<K, V>) where K: Clone + Ord, V: Clone + Ord {
        map.map.push((tree.k.clone(), index, tree.v.clone()));
        for child in tree.children.iter() {
            index += 1;
            Self::recurse_tree(index, &child, map);
        }
    }
    pub fn from_tree(tree: Tree<K, V>) -> Self where K: Clone + Ord, V: Clone + Ord {
        let mut map = ComponentMap {
            map: Vec::new(),
        };
        Self::recurse_tree(0, &tree, &mut map);
        map.map.sort();
        map
    }
    pub fn get(&self, k: &K) -> Option<&V> where K: Ord {
        let mut index = self.map.binary_search_by(|(key, _, _)| key.cmp(k)).ok()?;
        // iterate back to the first instance matching that key (this is linear, but will rarely recur very often)
        loop {
            if index == 0 { break; }
            let (ref key, _, _) = self.map[index - 1];
            if key != k { break; }
            index -= 1;
        }
        Some(&self.map[index].2)
    }
}

#[derive(Clone, Ord, PartialOrd, Eq, PartialEq)]
struct ObjectComponentEntry {
    value: Vec<u8>,
    children: usize,
}

#[derive(Clone, Ord, PartialOrd, Eq, PartialEq)]
pub struct TType {
    definition: Vec<u8>,
}
pub struct Obj {
    // the component tree contents, sorted by type, preorder index, and tree index
    map: ComponentMap<TType, usize>,
    // flattened pre-order representation of the tree structure
    components: Vec<ObjectComponentEntry>,
}

// a view onto the object, showing a segment, one component, which can be further upcast
pub struct Component<'a> {
    pub parent: &'a Obj,
    pub index: usize,
    pub children: &'a [ObjectComponentEntry],
}
impl Obj {
    pub fn upcast<'a> (&'a self, k: &TType) -> Option<Component<'a>> {
        let index = self.map.get(k)?;
        Some(Component {
            parent: self,
            index: *index,
            children: &self.components[*index .. (*index + self.components[*index].children)],
        })
    }
}
impl<'a> Component<'a> {
    pub fn upcast(&self, k: &TType) -> Option<Component<'a>> {
        let index = self.parent.map.get(k)?;
        Some(Component {
            parent: self.parent,
            index: *index,
            children: &self.parent.components[*index .. (*index + self.parent.components[*index].children)],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        
    }
}
