package main

import "testing"

func TestMatching(t *testing.T) {
	if Dispatch("GET", "/users/12").Route != "user_get" {
		t.Fatal("param route")
	}
	if Dispatch("GET", "//users//12/").Status != 200 || Dispatch("GET", "/users/12/extra").Status != 404 {
		t.Fatal("segments")
	}
	if Dispatch("POST", "/health").Allow != "GET" {
		t.Fatal("405 allow")
	}
	if got := Render("GET", "/files/a/b/c"); got != "GET /files/a/b/c -> 200 route=file_get params=path=a/b/c" {
		t.Fatal(got)
	}
}

func TestQueryDecoding(t *testing.T) {
	if got := Render("GET", "/users?b=2&a=x%41+y"); got != "GET /users?b=2&a=x%41+y -> 200 route=user_list query=a=xA y,b=2" {
		t.Fatal(got)
	}
}
