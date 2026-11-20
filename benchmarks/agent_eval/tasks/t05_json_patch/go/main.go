// t05_json_patch: RFC 7386 merge patch + validation with error chains (encoding/json)
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
)

const Base = `{"server":{"host":"localhost","port":8080,"tls":false},"limits":{"max_conn":100,"timeout_ms":5000},"log":{"level":"info"},"features":["a","b"]}`

var Patches = []string{
	`{"server":{"port":9090,"tls":true},"log":{"level":"debug"},"features":["a","b","c"]}`,
	`{"server":{"port":70000},"limits":{"timeout_ms":null}}`,
	`{"server":{"host":null}}`,
	`{"log":{"level":"verbose"},"limits":{"max_conn":0}}`,
	`{"server": {"port": 1}`,
	`{"server":"oops"}`,
}

func Parse(src string) (any, error) {
	dec := json.NewDecoder(bytes.NewReader([]byte(src)))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("trailing data")
	}
	return v, nil
}

// MergePatch implements RFC 7386 without mutating its inputs.
func MergePatch(target, patch any) any {
	p, ok := patch.(map[string]any)
	if !ok {
		return patch
	}
	out := map[string]any{}
	if t, ok := target.(map[string]any); ok {
		for k, v := range t {
			out[k] = v
		}
	}
	for k, v := range p {
		if v == nil {
			delete(out, k)
		} else {
			out[k] = MergePatch(out[k], v)
		}
	}
	return out
}

// Canonical relies on encoding/json sorting map keys.
func Canonical(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func member(obj map[string]any, key, path string) (any, error) {
	v, ok := obj[key]
	if !ok {
		return nil, errors.New(path + ": missing")
	}
	return v, nil
}

func getObj(obj map[string]any, key, path string) (map[string]any, error) {
	v, err := member(obj, key, path)
	if err != nil {
		return nil, err
	}
	o, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New(path + ": expected object")
	}
	return o, nil
}

func getStr(obj map[string]any, key, path string) (string, error) {
	v, err := member(obj, key, path)
	if err != nil {
		return "", err
	}
	s, ok := v.(string)
	if !ok {
		return "", errors.New(path + ": expected string")
	}
	return s, nil
}

func getInt(obj map[string]any, key, path string) (int64, error) {
	v, err := member(obj, key, path)
	if err != nil {
		return 0, err
	}
	n, ok := v.(json.Number)
	if !ok {
		return 0, errors.New(path + ": expected int")
	}
	i, err := strconv.ParseInt(string(n), 10, 64)
	if err != nil {
		return 0, errors.New(path + ": expected int")
	}
	return i, nil
}

func getBool(obj map[string]any, key, path string) (bool, error) {
	v, err := member(obj, key, path)
	if err != nil {
		return false, err
	}
	b, ok := v.(bool)
	if !ok {
		return false, errors.New(path + ": expected bool")
	}
	return b, nil
}

func Validate(cfg any) error {
	root, ok := cfg.(map[string]any)
	if !ok {
		return errors.New("root: expected object")
	}
	server, err := getObj(root, "server", "server")
	if err != nil {
		return err
	}
	host, err := getStr(server, "host", "server.host")
	if err != nil {
		return err
	}
	if host == "" {
		return errors.New("server.host: expected string")
	}
	port, err := getInt(server, "port", "server.port")
	if err != nil {
		return err
	}
	if port < 1 || port > 65535 {
		return fmt.Errorf("server.port: %d out of range 1..65535", port)
	}
	if _, err := getBool(server, "tls", "server.tls"); err != nil {
		return err
	}
	limits, err := getObj(root, "limits", "limits")
	if err != nil {
		return err
	}
	maxConn, err := getInt(limits, "max_conn", "limits.max_conn")
	if err != nil {
		return err
	}
	if maxConn <= 0 {
		return errors.New("limits.max_conn: must be > 0")
	}
	logCfg, err := getObj(root, "log", "log")
	if err != nil {
		return err
	}
	level, err := getStr(logCfg, "level", "log.level")
	if err != nil {
		return err
	}
	switch level {
	case "debug", "info", "warn", "error":
		return nil
	}
	return errors.New("log.level: invalid value " + level)
}

func ApplyOne(base any, patchSrc string) string {
	p, err := Parse(patchSrc)
	if err != nil {
		return "parse error"
	}
	merged := MergePatch(base, p)
	if err := Validate(merged); err != nil {
		return "invalid: " + err.Error()
	}
	return "ok: " + Canonical(merged)
}

func main() {
	base, err := Parse(Base)
	if err != nil {
		panic(err)
	}
	fmt.Println("base: " + Canonical(base))
	for i, p := range Patches {
		fmt.Printf("patch%d %s\n", i+1, ApplyOne(base, p))
	}
}
