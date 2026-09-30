// exitip is a developer tool: prints the public exit IP seen through each config of an Xray JSON subscription.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"

	xnet "github.com/xtls/xray-core/common/net"
)

func main() {
	file := flag.String("sub", "", "Xray JSON subscription file")
	match := flag.String("match", "", "only configs whose remarks contain this text")
	flag.Parse()
	raw, _ := os.ReadFile(*file)
	var configs []map[string]any
	if err := json.Unmarshal(raw, &configs); err != nil {
		panic(err)
	}
	for _, c := range configs {
		remarks, _ := c["remarks"].(string)
		if *match != "" && !strings.Contains(remarks, *match) {
			continue
		}
		delete(c, "inbounds")
		c["log"] = map[string]any{"loglevel": "none"}
		b, _ := json.Marshal(c)
		cfg, err := serial.LoadJSONConfig(strings.NewReader(string(b)))
		if err != nil {
			fmt.Println("ERR", remarks, err)
			continue
		}
		inst, err := core.New(cfg)
		if err != nil || inst.Start() != nil {
			fmt.Println("ERR start", remarks, err)
			continue
		}
		client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				dest, err := xnet.ParseDestination(network + ":" + addr)
				if err != nil {
					return nil, err
				}
				return core.Dial(ctx, inst, dest)
			},
		}}
		ip := "?"
		if resp, err := client.Get("https://ifconfig.me/ip"); err == nil {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			ip = strings.TrimSpace(string(body))
		} else {
			ip = "error: " + err.Error()
		}
		inst.Close()
		fmt.Printf("%-16s %s\n", ip, remarks)
	}
}
