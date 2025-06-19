/// the following code illustrates how to represent modular objects in an extremely efficient way, consisting ultimately of just two arrays, where upcasts (of upcasts) are just a binary search.
/// in summary: the component tree is flattened to pre-order. The component map is stored as a sorted array of (key, preorder-index, value) tuples. When you're narrowed in on a particular subcomponent, you can still look up a subcomponent of that subcomponent in logarithmic time from the root map of the object by restricting answers to not just (key, _, _) but (key, i, _) .. (key, i + c, _) where i is the index of the subcomponent parent and c is the number of children of the parent.
/// obviously this isn't very good if you need to mutate the object, but generally, states and messages are represented as immutable objects.

/// a simpler non-flat representation of the component tree. Although parsing IRL might not actually allocate a representation like this, it's here to illustrate how a tree maps to the preorder flattening.
pub struct Tree<K, V> {
    k: K,
    v: V,
    children: Vec<Tree<K, V>>,
}

type ObjectValue = Vec<u8>;

#[derive(Clone, Ord, PartialOrd, Eq, PartialEq, Debug)]
pub struct ObjectComponentEntry {
    pub value: ObjectValue,
    /// includes the self, so always at least 1
    pub total_descendent_count: usize,
    /// we don't entirely need to keep this, since it can just be rederived from the index by recursing down from the top of the obj without a change in time complexity, but it simplifies the code
    /// it turns out it does use an additional word, things aren't packed to powers of two beyond the word scale
    pub parent_index: usize,
}

#[derive(Clone, Ord, PartialOrd, Eq, PartialEq, Debug)]
pub struct TType {
    pub definition: Vec<u8>,
}

/// the highest level overview of an object
pub struct Obj {
    /// the component tree contents, sorted by (type, preorder index) (the value is stored in `components` at that index)
    pub map: Vec<(TType, usize)>,
    /// flattened pre-order representation of the tree structure
    pub components: Vec<ObjectComponentEntry>,
}

// a view onto the object, showing a segment of a specific type, one component, which can be further upcast into more refined components if needed.
pub struct Component<'a> {
    pub parent: &'a Obj,
    pub index: usize,
}
impl<'a> Component<'a> {
    pub fn value(&self) -> &'a ObjectValue {
        &self.parent.components[self.index].value
    }
    pub fn children(&self) -> &'a [ObjectComponentEntry] {
        &self.parent.components[self.index .. (self.index + self.parent.components[self.index].total_descendent_count)]
    }
}
impl Obj {
    fn recurse_tree(&mut self, mut index: usize, parent_index: usize, tree: &Tree<TType, ObjectValue>)-> usize {
        self.map.push((tree.k.clone(), index));
        self.components.push(ObjectComponentEntry {
            value: tree.v.clone(),
            total_descendent_count: 0, //could be core::mem::uninitialized... but nah
            parent_index: parent_index,
        });
        let self_index = index;
        index += 1;
        for child in tree.children.iter() {
            index = self.recurse_tree(index, self_index, child);
        }
        self.components[self_index].total_descendent_count = index - self_index;
        index
    }
    pub fn from_tree(tree: Tree<TType, ObjectValue>) -> Self {
        // remember that children.len of a tree doesn't translate straight to total_descendent_count of an ObjectComponentEntry, you have to recurse and return to get the sum of all descendents before you can set that.
        let mut ret = Obj {
            map: Vec::new(),
            components: Vec::new(),
        };
        ret.recurse_tree(0, 0, &tree);
        ret.map.sort();
        ret
    }
    // returns index within map, or None if not found
    pub fn get(&self, k: &TType) -> Option<usize> {
        // by searching for index:0, we will rarely get a direct hit, but if there is an entry of that type, the error case will land on the first one, which is what we want
        match self.map.binary_search_by(|(key, kindex)| key.cmp(k).then(kindex.cmp(&0))) {
            Ok(i) => { Some(i) },
            Err(i) => {
                if i >= self.map.len() { return None; }
                if &self.map[i].0 == k {
                    Some(i)
                }else{
                    None
                }
            }
        }
    }
    // returns index within map, or None if not found
    pub fn get_within(&self, k: &TType, start: usize, end: usize) -> Option<usize> {
        match self.map.binary_search_by(|(ttype, tindex)| ttype.cmp(k).then(tindex.cmp(&start))) {
            Ok(i) => { Some(i) }
            Err(i) => {
                if i >= self.map.len() { return None; }
                let (ref key, _) = self.map[i];
                if key != k { return None; }
                if i >= end { return None; }
                // with all those conditions passed, we know that i will point to the smallest matching type within the range
                Some(i)
            }
        }
    }
    pub fn upcast<'a> (&'a self, k: &TType) -> Option<Component<'a>> {
        let index = self.map[self.get(k)?].1;
        Some(Component {
            parent: self,
            index: index,
        })
    }
}
impl<'a> Component<'a> {
    pub fn upcast(&self, k: &TType) -> Option<Component<'a>> {
        let index = self.parent.map[self.parent.get_within(k, self.index, self.index + self.parent.components[self.index].total_descendent_count)?].1;
        Some(Component {
            parent: self.parent,
            index: index,
        })
    }
    pub fn downcast(&self, k: &TType) -> Option<Component<'a>> {
        // upcasts, and as long as that fails, looks to its immediate parent, repeat
        let mut eye = self.index;
        loop {
            let tc = Component { parent: self.parent, index: eye };
            if let Some(c) = tc.upcast(k) {
                return Some(c);
            }
            if eye == 0 { return None; }
            eye = self.parent.components[eye].parent_index;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    // fn from_ov(vec: ObjectValue)-> u64 {
    //     u64::from_le_bytes(vec.try_into().unwrap_or_default())
    // }
    fn to_ov(v: u64)-> ObjectValue {
        v.to_le_bytes().to_vec()
    }
    
    #[test]
    fn it_works() {
        let at = TType { definition: to_ov(1) };
        let bt = TType { definition: to_ov(2) };
        let ct = TType { definition: to_ov(3) };
        let dt = TType { definition: to_ov(4) };
        let tree = Tree {
            k: at,
            v: to_ov(1),
            children: vec![
                Tree {
                    k: dt.clone(),
                    v: to_ov(5),
                    children: vec![
                        Tree {
                            k: bt.clone(),
                            v: to_ov(2),
                            children: vec![],
                        },
                    ],
                },
                Tree {
                    k: ct.clone(),
                    v: to_ov(4),
                    children: vec![
                        Tree {
                            k: bt.clone(),
                            v: to_ov(3),
                            children: vec![],
                        }
                    ]
                }
            ]
        };
        let obj = Obj::from_tree(tree);
        println!("{:?}", obj.map);
        assert_eq!(obj.upcast(&bt).unwrap().value(), &to_ov(2));
        assert_eq!(obj.upcast(&ct).unwrap().upcast(&bt).unwrap().value(), &to_ov(3));
        assert_eq!(obj.upcast(&ct).unwrap().downcast(&dt).unwrap().value(), &to_ov(5));
    }
}
