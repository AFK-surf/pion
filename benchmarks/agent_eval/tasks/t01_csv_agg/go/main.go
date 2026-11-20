// t01_csv_agg: CSV parsing + grouped aggregation
package main

import (
	"fmt"
	"sort"
	"strings"
)

type RegionAgg struct {
	Region  string
	Rows    int
	Qty     int
	Revenue int
}

type Report struct {
	Regions []RegionAgg
	Invalid int
}

const Sample = "region,product,qty,price_cents\nnorth,apple,3,120\nsouth,banana,12,25\n\n north , pear , 2 , 310 \r\neast,kiwi,x,50\nwest,plum,4\nsouth,apple,1,120\neast,grape,10,15\nnorth,apple,-1,120\n   \nwest,fig,0,999\n"

// ParseUint accepts an unsigned decimal with 1..9 digits.
func ParseUint(s string) (int, bool) {
	if len(s) == 0 || len(s) > 9 {
		return 0, false
	}
	v := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
	}
	return v, true
}

func Aggregate(csv string) Report {
	byRegion := map[string]*RegionAgg{}
	invalid := 0
	seenHeader := false
	for _, raw := range strings.Split(csv, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if !seenHeader {
			seenHeader = true
			continue
		}
		fields := strings.Split(line, ",")
		if len(fields) != 4 {
			invalid++
			continue
		}
		for i := range fields {
			fields[i] = strings.TrimSpace(fields[i])
		}
		q, okQ := ParseUint(fields[2])
		p, okP := ParseUint(fields[3])
		if !okQ || !okP {
			invalid++
			continue
		}
		a, ok := byRegion[fields[0]]
		if !ok {
			a = &RegionAgg{Region: fields[0]}
			byRegion[fields[0]] = a
		}
		a.Rows++
		a.Qty += q
		a.Revenue += q * p
	}
	names := make([]string, 0, len(byRegion))
	for k := range byRegion {
		names = append(names, k)
	}
	sort.Strings(names)
	regions := make([]RegionAgg, 0, len(names))
	for _, n := range names {
		regions = append(regions, *byRegion[n])
	}
	return Report{Regions: regions, Invalid: invalid}
}

func FormatReport(r Report) string {
	var sb strings.Builder
	total := 0
	for _, a := range r.Regions {
		fmt.Fprintf(&sb, "%s rows=%d qty=%d revenue=%d\n", a.Region, a.Rows, a.Qty, a.Revenue)
		total += a.Revenue
	}
	fmt.Fprintf(&sb, "invalid=%d\ntotal_revenue=%d", r.Invalid, total)
	return sb.String()
}

func main() {
	fmt.Println(FormatReport(Aggregate(Sample)))
}
