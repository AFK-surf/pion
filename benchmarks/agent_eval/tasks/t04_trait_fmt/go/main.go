// t04_trait_fmt: interfaces, generic static dispatch, interface-slice heterogeneous collection
package main

import (
	"fmt"
	"strings"
)

type Summary interface{ Summary() string }
type Serializable interface{ ToKV() string }

// Item is both; any type implementing the two methods satisfies it implicitly.
type Item interface {
	Summary
	Serializable
}

type Article struct {
	Title, Author string
	Words         int
}

type Tweet struct {
	User, Text string
	Likes      int
}

type Metric struct {
	Name  string
	Value int
	Unit  string
}

func shorten(s string) string {
	if len(s) > 20 {
		return s[:17] + "..."
	}
	return s
}

func (a Article) Summary() string {
	return fmt.Sprintf("Article: %s by %s (%d words)", a.Title, a.Author, a.Words)
}
func (a Article) ToKV() string {
	return fmt.Sprintf("type=article;title=%s;author=%s;words=%d", a.Title, a.Author, a.Words)
}
func (t Tweet) Summary() string {
	unit := "likes"
	if t.Likes == 1 {
		unit = "like"
	}
	return fmt.Sprintf("@%s: %s [%d %s]", t.User, shorten(t.Text), t.Likes, unit)
}
func (t Tweet) ToKV() string { return fmt.Sprintf("type=tweet;user=%s;likes=%d", t.User, t.Likes) }
func (m Metric) Summary() string {
	return fmt.Sprintf("%s = %d %s", m.Name, m.Value, m.Unit)
}
func (m Metric) ToKV() string {
	return fmt.Sprintf("type=metric;name=%s;value=%d;unit=%s", m.Name, m.Value, m.Unit)
}

func RenderAll[T Summary](items []T) string {
	lines := make([]string, len(items))
	for i, x := range items {
		lines[i] = fmt.Sprintf("%d. %s", i+1, x.Summary())
	}
	return strings.Join(lines, "\n")
}

func Describe[T Item](x T) string { return x.Summary() + " | " + x.ToKV() }

func Mixed() []Item {
	return []Item{
		Article{"Agents and Compilers", "Ada", 1200},
		Tweet{"grace", "shipping structured diagnostics today", 42},
		Tweet{"linus", "ok", 1},
		Metric{"p99_latency", 87, "ms"},
	}
}

func main() {
	items := Mixed()
	fmt.Println(RenderAll(items))
	for _, it := range items {
		fmt.Println(Describe(it))
	}
	fmt.Println(RenderAll([]Metric{{"p99_latency", 87, "ms"}, {"cpu", 63, "%"}}))
}
