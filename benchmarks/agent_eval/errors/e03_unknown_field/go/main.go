package main

import "fmt"

type User struct {
	Name string
	Age  int
}

func main() {
	u := User{Name: "ada", Age: 36}
	fmt.Println(u.Agee)
}
