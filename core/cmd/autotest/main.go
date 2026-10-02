// autotest is a developer tool: it runs one auto-select config of an Xray JSON subscription file
// and prints what the observatory sees, to watch how auto-select behaves over time.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"furkvpn/core/libxray"
)

func main() {
	file := flag.String("sub", "", "Xray JSON subscription file (array of configs)")
	index := flag.Int("i", 1, "config index")
	every := flag.Duration("every", 15*time.Second, "print interval")
	total := flag.Duration("for", 3*time.Minute, "run time")
	flag.Parse()
	raw, err := os.ReadFile(*file)
	if err != nil {
		panic(err)
	}
	var configs []json.RawMessage
	if err := json.Unmarshal(raw, &configs); err != nil {
		panic(err)
	}
	measured, err := libxray.MeasureOutbounds(string(configs[*index]), "https://www.gstatic.com/generate_204", 5000)
	fmt.Println("each server separately:", measured, err)
	if err := libxray.Start(string(configs[*index]), -1); err != nil {
		panic(err)
	}
	time.Sleep(5 * time.Second)
	fmt.Println("after start:", libxray.ObservatoryStatus())
	started := time.Now()
	libxray.RecheckServers()
	fmt.Printf("recheck took %v: %s\n", time.Since(started).Round(time.Millisecond), libxray.ObservatoryStatus())
	defer libxray.Stop()
	start := time.Now()
	for time.Since(start) < *total {
		time.Sleep(*every)
		fmt.Printf("%5.0fs %s\n", time.Since(start).Seconds(), libxray.ObservatoryStatus())
	}
}
