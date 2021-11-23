package main

import (
  "bytes"
  "encoding/json"
  "fmt"
  "io/ioutil"
  "log"
  "os"

  "howett.net/plist"
)

func main() {
  stderr := log.New(os.Stderr, "", 0)
  stdinbytes, err := ioutil.ReadAll(os.Stdin)
  if err != nil {
    stderr.Fatalln(err)
  }
  decoder := plist.NewDecoder(bytes.NewReader(stdinbytes))

  var any map[string]interface{}
  decoder.Decode(&any)

  jsonOut, err := json.Marshal(&any)
  if err != nil {
    stderr.Fatalln(err)
  }

  fmt.Print(string(jsonOut))
}
