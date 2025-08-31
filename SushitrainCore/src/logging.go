package sushitrain

import (
	"context"
	"fmt"
	"io"
	"log"
	"log/slog"
	"regexp"
	"strings"
)

type stackedHandler struct {
	handler slog.Handler
	attrs   []slog.Attr
}

func (s *stackedHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return s.handler.Enabled(ctx, level)
}

func (s *stackedHandler) Handle(ctx context.Context, r slog.Record) error {
	rec := r.Clone()
	rec.AddAttrs(s.attrs...)
	return s.handler.Handle(ctx, rec)
}

func (s *stackedHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &stackedHandler{
		handler: s.handler,
		attrs:   append(s.attrs, attrs...),
	}
}

func (s *stackedHandler) WithGroup(name string) slog.Handler {
	return &stackedHandler{
		handler: s.handler,
		attrs:   append(s.attrs, slog.String("group", name)),
	}
}

var _ slog.Handler = (*stackedHandler)(nil)

type logTail struct {
	lines    []string
	maxLines int
	lastLine int
}

func newLogTail(maxLines int) *logTail {
	return &logTail{
		lines:    make([]string, maxLines),
		maxLines: maxLines,
		lastLine: maxLines,
	}
}

func (lt *logTail) append(line string) {
	lt.lastLine += 1
	lt.lastLine %= lt.maxLines
	lt.lines[lt.lastLine] = line
}

var deviceIDTailRegexp = regexp.MustCompile("(-[A-Z0-9]{7}){7}")
var ipHeadRegexp = regexp.MustCompile("(([0-9]{1,3}\\.){3})|(([0-9a-fA-F]{1,4}:){4})")
var pathsRegexp = regexp.MustCompile("/Users/[^/]+/")
var uuidTailRegexp = regexp.MustCompile("-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")

func redactLog(line string) string {
	line = deviceIDTailRegexp.ReplaceAllString(line, "•••")
	line = ipHeadRegexp.ReplaceAllString(line, "•••.•••.•••.")
	line = pathsRegexp.ReplaceAllString(line, "/Users/•••/")
	line = uuidTailRegexp.ReplaceAllString(line, "-•••")
	return line
}

func (lt *logTail) write(to io.Writer, redact bool) error {
	startIndex := (lt.lastLine + 1) % lt.maxLines
	for i := startIndex; i < lt.maxLines; i++ {
		line := lt.lines[i]
		if len(line) > 0 {
			if redact {
				line = redactLog(line)
			}
			_, err := to.Write([]byte(line + "\n"))
			if err != nil {
				return err
			}
		}
	}

	for i := 0; i < lt.lastLine; i++ {
		line := lt.lines[i]
		if len(line) > 0 {
			if redact {
				line = redactLog(line)
			}
			_, err := to.Write([]byte(line + "\n"))
			if err != nil {
				return err
			}
		}
	}

	return nil
}

type logHandler struct {
	logger   *log.Logger
	minLevel slog.Level
	tail     *logTail
}

var _ slog.Handler = (*logHandler)(nil)

func (h *logHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return level >= h.minLevel
}

func (h *logHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &stackedHandler{
		handler: h,
		attrs:   attrs,
	}
}

func (h *logHandler) WithGroup(name string) slog.Handler {
	return &stackedHandler{
		handler: h,
		attrs:   []slog.Attr{slog.String("group", name)},
	}
}

func (h *logHandler) Handle(ctx context.Context, r slog.Record) error {
	var sb strings.Builder
	r.Attrs(func(a slog.Attr) bool {
		sb.WriteString(a.Key)
		sb.WriteRune('=')
		sb.WriteString(a.Value.String())
		sb.WriteRune(' ')
		return true
	})

	timeStr := r.Time.Format("[15:04:05.000] ")
	logMessage := fmt.Sprint(timeStr, r.Level.String(), " ", r.Message, " ", sb.String())
	h.logger.Println(logMessage)
	h.tail.append(logMessage)

	return nil
}

func newLogHandler(out io.Writer, minLevel slog.Level) *logHandler {
	h := &logHandler{
		logger:   log.New(out, "", 0),
		minLevel: minLevel,
		tail:     newLogTail(1000),
	}

	return h
}
