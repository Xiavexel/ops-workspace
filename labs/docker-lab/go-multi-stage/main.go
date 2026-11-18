package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		hostname, _ := os.Hostname()
		fmt.Fprintln(w, "Hello from Go!")
		fmt.Fprintln(w, "Hostname:", hostname)
		fmt.Fprintln(w, "Path:", r.URL.Path)
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte("OK"))
	})

	fmt.Println("Server starting on :8080")
	http.ListenAndServe(":8080", nil)
}
