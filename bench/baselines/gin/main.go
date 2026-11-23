package main

import (
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
)

type Message struct {
	Message string `json:"message"`
}

func main() {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.GET("/plaintext", func(c *gin.Context) {
		c.String(http.StatusOK, "Hello, World!")
	})
	r.GET("/json", func(c *gin.Context) {
		c.JSON(http.StatusOK, Message{Message: "Hello, World!"})
	})
	addr := "127.0.0.1:18081"
	if a := os.Getenv("ADDR"); a != "" {
		addr = a
	}
	if err := r.Run(addr); err != nil {
		panic(err)
	}
}
