// xtest is a developer tool: it measures delay for every config of an Xray JSON subscription file.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sync"

	"furkvpn/core/libxray"
)

func main() {
	file := flag.String("sub", "", "Xray JSON subscription file (array of configs)")
	url := flag.String("url", "https://www.gstatic.com/generate_204", "test URL")
	flag.Parse()
	raw, err := os.ReadFile(*file)
	if err != nil {
		panic(err)
	}
	var configs []json.RawMessage
	if err := json.Unmarshal(raw, &configs); err != nil {
		panic(err)
	}
	fmt.Println("xray", libxray.XrayVersion(), "configs:", len(configs))
	type res struct {
		remarks string
		ms      int64
		err     error
	}
	out := make([]res, len(configs))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, c := range configs {
		var meta struct{ Remarks string `json:"remarks"` }
		_ = json.Unmarshal(c, &meta)
		if err := libxray.ValidateConfig(string(c)); err != nil {
			out[i] = res{meta.Remarks, -1, fmt.Errorf("invalid: %w", err)}
			continue
		}
		wg.Add(1)
		go func(i int, c string, remarks string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			ms, err := libxray.MeasureDelay(c, *url, 5000)
			out[i] = res{remarks, ms, err}
		}(i, string(c), meta.Remarks)
	}
	wg.Wait()
	for _, r := range out {
		if r.err != nil {
			fmt.Printf("%6s  %s  (%v)\n", "ERR", r.remarks, r.err)
		} else {
			fmt.Printf("%4dms  %s\n", r.ms, r.remarks)
		}
	}
}
