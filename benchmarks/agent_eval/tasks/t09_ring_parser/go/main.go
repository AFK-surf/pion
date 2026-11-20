// t09_ring_parser: incremental frame parser over a 16-byte ring buffer
package main

import (
	"encoding/hex"
	"fmt"
)

const (
	Cap   = 16
	Magic = 0xAA
)

type FrameParser struct {
	buf                                       [Cap]byte
	head, Count                               int
	Frames                                    []string
	BadChecksum, BadLength, Skipped, Overflow int
}

func (p *FrameParser) peek(i int) byte { return p.buf[(p.head+i)%Cap] }

func (p *FrameParser) dropFront(n int) {
	p.head = (p.head + n) % Cap
	p.Count -= n
}

func (p *FrameParser) parseAvailable() {
	for p.Count > 0 {
		if p.peek(0) != Magic {
			p.dropFront(1)
			p.Skipped++
			continue
		}
		if p.Count < 2 {
			return
		}
		n := int(p.peek(1))
		if n > 8 {
			p.BadLength++
			p.dropFront(1)
			continue
		}
		if p.Count < n+3 {
			return
		}
		payload := make([]byte, n)
		var sum byte
		for i := range payload {
			payload[i] = p.peek(2 + i)
			sum += payload[i]
		}
		if sum != p.peek(2+n) {
			p.BadChecksum++
			p.dropFront(1)
			continue
		}
		if n == 0 {
			p.Frames = append(p.Frames, "-")
		} else {
			p.Frames = append(p.Frames, hex.EncodeToString(payload))
		}
		p.dropFront(n + 3)
	}
}

func (p *FrameParser) Feed(chunk []byte) {
	for _, b := range chunk {
		if p.Count == Cap {
			p.Overflow++
			continue
		}
		p.buf[(p.head+p.Count)%Cap] = b
		p.Count++
	}
	p.parseAvailable()
}

var Stream = []byte{
	1, 2,
	0xAA, 3, 0x10, 0x20, 0x30, 0x60,
	0xAA, 2, 5, 6, 0,
	0xAA, 0, 0,
	0xAA, 9,
	0xAA, 4, 0xDE, 0xAD, 0xBE, 0xEF, 0x38,
	0xAA, 1, 0xAA, 0xAA,
	0xAA, 5, 1, 2,
}

func Run(chunkSize int) *FrameParser {
	p := &FrameParser{}
	for i := 0; i < len(Stream); i += chunkSize {
		p.Feed(Stream[i:min(i+chunkSize, len(Stream))])
	}
	return p
}

func Summary(p *FrameParser) string {
	return fmt.Sprintf("ok=%d bad_checksum=%d bad_length=%d skipped=%d pending=%d",
		len(p.Frames), p.BadChecksum, p.BadLength, p.Skipped, p.Count)
}

func main() {
	p := Run(5)
	for _, f := range p.Frames {
		fmt.Println("frame " + f)
	}
	fmt.Println(Summary(p))
}
