/*
 Simple use of bcrypt library to implement a password hashing
 see https://en.wikipedia.org/wiki/Bcrypt
*/
package main

import (
	"fmt"
	"golang.org/x/crypto/bcrypt"
	"os"
)

func main() {
	if len(os.Args) > 1 {
		arg := os.Args[1]
		if len(arg) > 0 {
			// Hashing the password with the default cost of 10
			password := []byte(arg)
			hashedPassword, err := bcrypt.GenerateFromPassword(password, bcrypt.DefaultCost)
			if err != nil {
				panic(err)
			}
			fmt.Println(string(hashedPassword))
		}
	}
}
