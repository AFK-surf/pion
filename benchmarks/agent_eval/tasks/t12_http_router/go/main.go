// t12_http_router: route matching + params + query parsing (net/url)
package main

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
)

type Route struct{ Method, Pattern, Name string }

var Routes = []Route{
	{"GET", "/health", "health"},
	{"GET", "/users", "user_list"},
	{"POST", "/users", "user_create"},
	{"GET", "/users/:id", "user_get"},
	{"DELETE", "/users/:id", "user_delete"},
	{"GET", "/files/*path", "file_get"},
}

type Outcome struct {
	Status        int
	Route         string
	Params, Query map[string]string
	Error, Allow  string
}

func segments(path string) []string {
	var out []string
	for _, s := range strings.Split(path, "/") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func bind(pattern string, segs []string) (map[string]string, bool) {
	pat := segments(pattern)
	params := map[string]string{}
	for i, p := range pat {
		if strings.HasPrefix(p, "*") {
			if i >= len(segs) {
				return nil, false
			}
			params[p[1:]] = strings.Join(segs[i:], "/")
			return params, true
		}
		if i >= len(segs) {
			return nil, false
		}
		if strings.HasPrefix(p, ":") {
			params[p[1:]] = segs[i]
		} else if p != segs[i] {
			return nil, false
		}
	}
	return params, len(pat) == len(segs)
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func Dispatch(method, target string) Outcome {
	path, rawQuery, _ := strings.Cut(target, "?")
	query := map[string]string{}
	values, _ := url.ParseQuery(rawQuery) // keeps every value; later duplicates win below
	for k, vs := range values {
		query[k] = vs[len(vs)-1]
	}
	segs := segments(path)
	var allowed []string
	for _, r := range Routes {
		params, ok := bind(r.Pattern, segs)
		if !ok {
			continue
		}
		if r.Method != method {
			allowed = append(allowed, r.Method)
			continue
		}
		if id, has := params["id"]; has && !allDigits(id) {
			return Outcome{Status: 400, Route: r.Name, Error: "invalid id"}
		}
		return Outcome{Status: 200, Route: r.Name, Params: params, Query: query}
	}
	if len(allowed) > 0 {
		sort.Strings(allowed)
		return Outcome{Status: 405, Allow: strings.Join(allowed, ",")}
	}
	return Outcome{Status: 404}
}

func kv(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + "=" + m[k]
	}
	return strings.Join(parts, ",")
}

func Render(method, target string) string {
	o := Dispatch(method, target)
	out := fmt.Sprintf("%s %s -> %d", method, target, o.Status)
	if o.Route != "" {
		out += " route=" + o.Route
	}
	if len(o.Params) > 0 {
		out += " params=" + kv(o.Params)
	}
	if len(o.Query) > 0 {
		out += " query=" + kv(o.Query)
	}
	if o.Error != "" {
		out += " error=" + o.Error
	}
	if o.Allow != "" {
		out += " allow=" + o.Allow
	}
	return out
}

func main() {
	reqs := []string{
		"GET /users?limit=10&sort=name",
		"GET /users/42?verbose=1",
		"GET /users/abc",
		"DELETE /users/7",
		"PUT /users/7",
		"GET /files/docs/readme.md?dl=true",
		"GET /nope",
		"GET /health?q=a%20b+c&q=last%2Bone",
		"POST /users/",
		"GET /files/",
	}
	for _, r := range reqs {
		m, t, _ := strings.Cut(r, " ")
		fmt.Println(Render(m, t))
	}
}
