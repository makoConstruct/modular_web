/// Tree just represents a simpler non-flat representation of the component tree. Although parsing IRL might not actually allocate a representation like this, it's here to illustrate how a simple tree can be taken as input.
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

/// as noted in the readme, the types should probably store more the `map` part of the Obj, since that structure never changes at runtime, it's the same for every instance of that type.
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
    // Obvously you're going to need this, but I'm not sure how this would be implemented!
    // pub fn children(&self) -> impl Iterator<Item = Component<'a>> {
    // }
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
    /// logarithmic if there's only one matching component, roughly log*log otherwise, fast either way.
    pub fn downcast(&self, k: &TType) -> Option<Component<'a>> {
        match self.parent.map.binary_search_by(|(ttype, tindex)| ttype.cmp(k).then(tindex.cmp(&self.index))) {
            Ok(i) => { Some(Component { parent: self.parent, index: i }) }
            Err(i) => {
                let get_at = |i: usize| -> Option<(TType, usize)> {
                    let es = self.parent.map[i].clone();
                    if &es.0 != k { return None; }
                    Some(es)
                };
                let prev = if i > 0 { get_at(i - 1) } else { None };
                let next = if i < self.parent.map.len() { get_at(i) } else { None };
                let complete = |o:Option<(TType, usize)>| -> Option<Component<'a>> {
                    o.map(|(_, i)| Component { parent: self.parent, index: i })
                };
                if prev.is_none() { return complete(next); }
                if next.is_none() { return complete(prev); }
                // this is the tricky case, if there are two adjacent entries, the downcast will be one or the other, but which one depends on the structure of the inheritance tree
                let pi = prev.as_ref().unwrap().1;
                let ni = next.as_ref().unwrap().1;
                let mut pari = self.parent.components[self.index].parent_index;
                loop {
                    if pari <= pi { return complete(prev); }
                    if pari + self.parent.components[pari].total_descendent_count > ni { return complete(next); }
                    pari = self.parent.components[pari].parent_index;
                }
            }
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
        // a diamond problem'd inheritance structure
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
