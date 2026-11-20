// t10_graph_topo: Kahn's algorithm, smallest-first, cycle detection
package main

import (
	"container/heap"
	"fmt"
	"sort"
	"strings"
)

type Topo struct {
	Order, Blocked []string
}

const (
	Graph1 = "shirt -> tie\ntie -> jacket\npants -> shoes\npants -> belt\nbelt -> jacket\nshirt -> belt\nsocks -> shoes\nundershorts -> pants\nundershorts -> shoes\nwatch\n"
	Graph2 = "a -> b\nb -> c\nc -> a\nc -> d\ne -> d\n"
	Graph3 = "a -> b\nb ->\n"
)

// nameHeap is a min-heap of node names.
type nameHeap []string

func (h nameHeap) Len() int           { return len(h) }
func (h nameHeap) Less(i, j int) bool { return h[i] < h[j] }
func (h nameHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *nameHeap) Push(x any)        { *h = append(*h, x.(string)) }
func (h *nameHeap) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

func Toposort(text string) (Topo, error) {
	adj := map[string][]string{}
	indeg := map[string]int{}
	seen := map[[2]string]bool{}
	var nodes []string
	add := func(n string) {
		if _, ok := indeg[n]; !ok {
			indeg[n] = 0
			nodes = append(nodes, n)
		}
	}
	for i, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		u, v, isEdge := strings.Cut(line, "->")
		if !isEdge {
			add(line)
			continue
		}
		u, v = strings.TrimSpace(u), strings.TrimSpace(v)
		if u == "" || v == "" {
			return Topo{}, fmt.Errorf("line %d: malformed edge '%s'", i+1, line)
		}
		add(u)
		add(v)
		if !seen[[2]string{u, v}] {
			seen[[2]string{u, v}] = true
			adj[u] = append(adj[u], v)
			indeg[v]++
		}
	}
	ready := &nameHeap{}
	for _, n := range nodes {
		if indeg[n] == 0 {
			heap.Push(ready, n)
		}
	}
	var order []string
	for ready.Len() > 0 {
		n := heap.Pop(ready).(string)
		order = append(order, n)
		for _, m := range adj[n] {
			indeg[m]--
			if indeg[m] == 0 {
				heap.Push(ready, m)
			}
		}
	}
	var blocked []string
	for _, n := range nodes {
		if indeg[n] > 0 {
			blocked = append(blocked, n)
		}
	}
	sort.Strings(blocked)
	return Topo{order, blocked}, nil
}

func Describe(label, text string) string {
	t, err := Toposort(text)
	switch {
	case err != nil:
		return label + " error: " + err.Error()
	case len(t.Blocked) == 0:
		return label + " order: " + strings.Join(t.Order, " ")
	default:
		return label + " cycle: ordered=" + strings.Join(t.Order, ",") + " blocked=" + strings.Join(t.Blocked, ",")
	}
}

func main() {
	fmt.Println(Describe("graph1", Graph1))
	fmt.Println(Describe("graph2", Graph2))
	fmt.Println(Describe("graph3", Graph3))
}
