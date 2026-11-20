// t03_lru_cache: O(1) LRU with a hash map + index-linked recency list
package main

import (
	"fmt"
	"strings"
)

type node struct {
	key        string
	val        int
	prev, next int
}

type LRU struct {
	cap                     int
	index                   map[string]int
	nodes                   []node
	head, tail              int
	Hits, Misses, Evictions int
}

func NewLRU(cap int) *LRU {
	return &LRU{cap: cap, index: map[string]int{}, head: -1, tail: -1}
}

func (c *LRU) unlink(i int) {
	p, n := c.nodes[i].prev, c.nodes[i].next
	if p >= 0 {
		c.nodes[p].next = n
	} else {
		c.head = n
	}
	if n >= 0 {
		c.nodes[n].prev = p
	} else {
		c.tail = p
	}
}

func (c *LRU) pushFront(i int) {
	c.nodes[i].prev = -1
	c.nodes[i].next = c.head
	if c.head >= 0 {
		c.nodes[c.head].prev = i
	}
	c.head = i
	if c.tail < 0 {
		c.tail = i
	}
}

func (c *LRU) Get(key string) (int, bool) {
	i, ok := c.index[key]
	if !ok {
		c.Misses++
		return 0, false
	}
	c.Hits++
	c.unlink(i)
	c.pushFront(i)
	return c.nodes[i].val, true
}

// Put returns the evicted key, if any.
func (c *LRU) Put(key string, val int) (string, bool) {
	if i, ok := c.index[key]; ok {
		c.nodes[i].val = val
		c.unlink(i)
		c.pushFront(i)
		return "", false
	}
	if len(c.nodes) < c.cap {
		c.nodes = append(c.nodes, node{key: key, val: val, prev: -1, next: -1})
		i := len(c.nodes) - 1
		c.index[key] = i
		c.pushFront(i)
		return "", false
	}
	victim := c.tail
	old := c.nodes[victim].key
	c.unlink(victim)
	delete(c.index, old)
	c.nodes[victim].key = key
	c.nodes[victim].val = val
	c.index[key] = victim
	c.pushFront(victim)
	c.Evictions++
	return old, true
}

func (c *LRU) Order() []string {
	var out []string
	for i := c.head; i >= 0; i = c.nodes[i].next {
		out = append(out, c.nodes[i].key)
	}
	return out
}

func RunScript() []string {
	c := NewLRU(3)
	var out []string
	put := func(k string, v int) {
		if old, ok := c.Put(k, v); ok {
			out = append(out, "evict "+old)
		}
	}
	get := func(k string) {
		if v, ok := c.Get(k); ok {
			out = append(out, fmt.Sprintf("get %s = %d", k, v))
		} else {
			out = append(out, fmt.Sprintf("get %s = miss", k))
		}
	}
	put("a", 1)
	put("b", 2)
	put("c", 3)
	get("a")
	put("d", 4)
	get("b")
	put("c", 30)
	put("e", 5)
	get("a")
	get("c")
	get("d")
	get("e")
	out = append(out, fmt.Sprintf("order=%s hits=%d misses=%d evictions=%d",
		strings.Join(c.Order(), ","), c.Hits, c.Misses, c.Evictions))
	return out
}

func main() {
	for _, l := range RunScript() {
		fmt.Println(l)
	}
}
