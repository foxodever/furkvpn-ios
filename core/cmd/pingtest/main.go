// pingtest is a developer tool: it pings every config of an Xray JSON subscription file the way the
// app's ping button does and prints the delays.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sync"
	"time"

	"furkvpn/core/libxray"
)

func main() {
	file := flag.String("sub", "", "Xray JSON subscription file (array of configs)")
	url := flag.String("url", "https://www.gstatic.com/generate_204", "test URL")
	timeout := flag.Int("timeout", 5000, "timeout, ms")
	flag.Parse()
	raw, err := os.ReadFile(*file)
	if err != nil {
		panic(err)
	}
	var configs []json.RawMessage
	if err := json.Unmarshal(raw, &configs); err != nil {
		panic(err)
	}
	results := make([]string, len(configs))
	var wg sync.WaitGroup
	limit := make(chan struct{}, 6)
	for i, c := range configs {
		wg.Add(1)
		go func(i int, c string) {
			defer wg.Done()
			limit <- struct{}{}
			defer func() { <-limit }()
			var remarks struct{ Remarks string }
			_ = json.Unmarshal([]byte(c), &remarks)
			started := time.Now()
			ms, err := libxray.MeasureDelay(c, *url, int32(*timeout))
			results[i] = fmt.Sprintf("%-40s %6d ms  (took %v) %v", remarks.Remarks, ms, time.Since(started).Round(time.Millisecond), errOrEmpty(err))
		}(i, string(c))
	}
	wg.Wait()
	for _, r := range results {
		fmt.Println(r)
	}
}

func errOrEmpty(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
