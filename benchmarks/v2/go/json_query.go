// V2 Benchmark 1: json_query (Go, hand-written lexer + recursive-descent AST, zero encoding/json)
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	jNull = iota
	jBool
	jInt
	jStr
	jArr
	jObj
)

type jsonEntry struct {
	key string
	val *jsonValue
}

type jsonValue struct {
	tag int
	b   bool
	i   int32
	s   string
	arr []*jsonValue
	obj []jsonEntry
}

type parser struct {
	src []byte
	pos int
}

func (p *parser) skipWS() {
	n := len(p.src)
	for p.pos < n {
		c := p.src[p.pos]
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			p.pos++
		} else {
			break
		}
	}
}

func (p *parser) parseStringRaw() string {
	p.pos++ // '"'
	start := p.pos
	n := len(p.src)
	scan := start
	hasEscape := false
	for scan < n {
		c := p.src[scan]
		if c == '"' {
			break
		}
		if c == '\\' {
			hasEscape = true
			break
		}
		scan++
	}
	if !hasEscape {
		s := string(p.src[start:scan])
		p.pos = scan + 1
		return s
	}
	buf := make([]byte, 0, 64)
	for p.pos < n {
		c := p.src[p.pos]
		p.pos++
		if c == '"' {
			return string(buf)
		}
		if c == '\\' && p.pos < n {
			e := p.src[p.pos]
			p.pos++
			switch e {
			case '"':
				buf = append(buf, '"')
			case '\\':
				buf = append(buf, '\\')
			case '/':
				buf = append(buf, '/')
			case 'b':
				buf = append(buf, '\b')
			case 'f':
				buf = append(buf, '\f')
			case 'n':
				buf = append(buf, '\n')
			case 'r':
				buf = append(buf, '\r')
			case 't':
				buf = append(buf, '\t')
			default:
				buf = append(buf, e)
			}
		} else {
			buf = append(buf, c)
		}
	}
	panic("unterminated string")
}

func (p *parser) parseArray() *jsonValue {
	p.pos++ // '['
	v := &jsonValue{tag: jArr}
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == ']' {
		p.pos++
		return v
	}
	for p.pos < len(p.src) {
		v.arr = append(v.arr, p.parseValue())
		p.skipWS()
		if p.pos < len(p.src) {
			c := p.src[p.pos]
			if c == ',' {
				p.pos++
				p.skipWS()
			} else if c == ']' {
				p.pos++
				return v
			} else {
				panic("expected ',' or ']'")
			}
		}
	}
	panic("unterminated array")
}

func (p *parser) parseObject() *jsonValue {
	p.pos++ // '{'
	v := &jsonValue{tag: jObj}
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos++
		return v
	}
	for p.pos < len(p.src) {
		p.skipWS()
		key := p.parseStringRaw()
		p.skipWS()
		p.pos++ // ':'
		val := p.parseValue()
		v.obj = append(v.obj, jsonEntry{key: key, val: val})
		p.skipWS()
		if p.pos < len(p.src) {
			c := p.src[p.pos]
			if c == ',' {
				p.pos++
				p.skipWS()
			} else if c == '}' {
				p.pos++
				return v
			} else {
				panic("expected ',' or '}'")
			}
		}
	}
	panic("unterminated object")
}

func (p *parser) parseValue() *jsonValue {
	p.skipWS()
	c := p.src[p.pos]
	switch c {
	case '{':
		return p.parseObject()
	case '[':
		return p.parseArray()
	case '"':
		return &jsonValue{tag: jStr, s: p.parseStringRaw()}
	case 't':
		p.pos += 4
		return &jsonValue{tag: jBool, b: true}
	case 'f':
		p.pos += 5
		return &jsonValue{tag: jBool, b: false}
	case 'n':
		p.pos += 4
		return &jsonValue{tag: jNull}
	default:
		neg := false
		if c == '-' {
			neg = true
			p.pos++
		}
		var acc int32
		for p.pos < len(p.src) {
			d := p.src[p.pos]
			if d >= '0' && d <= '9' {
				acc = acc*10 + int32(d-'0')
				p.pos++
			} else {
				break
			}
		}
		if neg {
			acc = -acc
		}
		return &jsonValue{tag: jInt, i: acc}
	}
}

func objGet(v *jsonValue, key string) *jsonValue {
	if v == nil || v.tag != jObj {
		return nil
	}
	for i := range v.obj {
		if v.obj[i].key == key {
			return v.obj[i].val
		}
	}
	return nil
}

func writeJSONEscaped(sb *strings.Builder, s string) {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		default:
			sb.WriteByte(c)
		}
	}
}

func polyHash(s string) int32 {
	var h uint32
	for i := 0; i < len(s); i++ {
		h = (h*31 + uint32(s[i])) & 0x3fffffff
	}
	return int32(h)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <dataset.json>\n", os.Args[0])
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	p := parser{src: data, pos: 0}
	root := p.parseValue()
	records := objGet(root, "records")
	if records == nil || records.tag != jArr {
		fmt.Fprintln(os.Stderr, "missing records")
		os.Exit(1)
	}

	roleCounts := make(map[string]int32, 16)
	tagCounts := make(map[string]int32, 16)
	var out strings.Builder
	out.Grow(4096)

	var total, matched, sumLat int32
	for _, rec := range records.arr {
		total++
		user := objGet(rec, "user")
		metrics := objGet(rec, "metrics")
		note := objGet(rec, "note").s

		idVal := objGet(user, "id").i
		role := objGet(user, "role").s
		active := objGet(user, "active").b
		lat := objGet(metrics, "latency_ms").i
		tags := objGet(metrics, "tags").arr

		roleCounts[role]++
		hasProd := false
		for _, tv := range tags {
			tagCounts[tv.s]++
			if tv.s == "prod" {
				hasProd = true
			}
		}
		if active && lat >= 150 && hasProd {
			matched++
			sumLat += lat
			out.WriteString(`{"id":`)
			out.WriteString(strconv.Itoa(int(idVal)))
			out.WriteString(`,"role":"`)
			writeJSONEscaped(&out, role)
			out.WriteString(`","lat":`)
			out.WriteString(strconv.Itoa(int(lat)))
			out.WriteString(`,"note":"`)
			writeJSONEscaped(&out, note)
			out.WriteString("\"}\n")
		}
	}

	var roleTagHash int32
	for k, v := range roleCounts {
		kh := uint32(polyHash(k))
		eh := ((kh*17 + uint32(v)) ^ 0x13579) & 0x3fffffff
		roleTagHash ^= int32(eh)
	}
	for k, v := range tagCounts {
		kh := uint32(polyHash(k))
		eh := ((kh*29 + uint32(v)) ^ 0x2468a) & 0x3fffffff
		roleTagHash ^= int32(eh)
	}

	outStr := out.String()
	outHash := polyHash(outStr)
	fmt.Printf("%d %d %d %d %d %d\n", total, matched, sumLat, roleTagHash, len(outStr), outHash)
}
