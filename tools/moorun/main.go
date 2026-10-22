// Command moorun is serialize.moo's test runner (DESIGN.md, "The runner").
//
// The moo CLI has no io library, so a moo test can neither open a file nor
// read stdin: inputs go IN as source and results come OUT on stdout. For each
// test directory test/<name>/ the runner builds a run directory
// build/run/<name>/:
//
//	build/run/<name>/          the working directory the interpreter runs in
//	build/run/<name>/<plant>   every file of test/<name>/plant/, planted one
//	                           level above the unit (the loading-is-closed tests)
//	build/run/<name>/src/      THE UNIT: a copy of src/*.moo, the .moo files of
//	                           test/<name>/, inputs.moo and _moorun.moo, the
//	                           driver
//
// inputs.moo maps a name to a file's text: every conformance/*.txt by its base
// name (bool for conformance/bool.txt), every conformance-controls/*.txt as
// control_<base>, and each path listed in test/<name>/inputs.list (one path
// per line, relative to the repository root) as its base name. A listed file
// that is missing fails the directory: never a skip.
//
// The driver requires each *_test.moo module (a table of functions), runs
// every function named Test<Name> in sorted order and prints RUN Test<Name>,
// then --- PASS Test<Name> or --- FAIL Test<Name> with the raise indented on
// the next line. The runner passes stdout through and exits nonzero on a FAIL,
// on an interpreter that exits nonzero, on a directory that runs no test, and
// on a missing or empty test/<name>/, naming it.
//
// Usage: moorun -root <repo> [name...]; no names runs every test/*/.
// The interpreter is $MOO, else <repo>/dist/moo/moo (make dist-moo).
//
// Standard library only; no time, no sockets, no network.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

func main() {
	root := flag.String("root", ".", "the repository root")
	flag.Parse()
	os.Exit(run(*root, flag.Args(), os.Stdout, os.Stderr))
}

func run(root string, names []string, stdout, stderr io.Writer) int {
	moo, why := interpreter(root)
	if moo == "" {
		fmt.Fprintf(stderr, "moorun: the moo interpreter does not resolve: %s\n", why)
		return 1
	}
	if len(names) == 0 {
		entries, err := os.ReadDir(filepath.Join(root, "test"))
		if err != nil {
			fmt.Fprintf(stderr, "moorun: test/ is missing: %v\n", err)
			return 1
		}
		for _, e := range entries {
			if e.IsDir() {
				names = append(names, e.Name())
			}
		}
		if len(names) == 0 {
			fmt.Fprintf(stderr, "moorun: test/ has no test directories\n")
			return 1
		}
	}
	failed := 0
	for _, name := range names {
		if !runDir(root, moo, name, stdout, stderr) {
			failed++
		}
	}
	if failed != 0 {
		fmt.Fprintf(stdout, "FAIL %d of %d test directories\n", failed, len(names))
		return 1
	}
	fmt.Fprintf(stdout, "ok %d test directories\n", len(names))
	return 0
}

// interpreter resolves $MOO, else the pinned dist/moo/moo.
func interpreter(root string) (string, string) {
	if p := os.Getenv("MOO"); p != "" {
		if lp, err := exec.LookPath(p); err == nil {
			return lp, ""
		}
		return "", fmt.Sprintf("$MOO=%s does not resolve; run make dist-moo (or unset MOO)", p)
	}
	p, err := filepath.Abs(filepath.Join(root, "dist", "moo", "moo"))
	if err != nil {
		return "", err.Error()
	}
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Sprintf("the pinned moo is not at %s; run make dist-moo", p)
	}
	return p, ""
}

var validName = regexp.MustCompile(`^[a-z0-9_]+$`)

// runDir builds build/run/<name>/ and runs its tests, reporting success.
func runDir(root, moo, name string, stdout, stderr io.Writer) bool {
	label := "test/" + name + "/"
	if !validName.MatchString(name) {
		fmt.Fprintf(stdout, "FAIL %s: not a test directory name ([a-z0-9_]+)\n", label)
		return false
	}
	testDir := filepath.Join(root, "test", name)
	if st, err := os.Stat(testDir); err != nil || !st.IsDir() {
		fmt.Fprintf(stdout, "FAIL %s is missing\n", label)
		return false
	}
	tests, _ := filepath.Glob(filepath.Join(testDir, "*_test.moo"))
	sort.Strings(tests)
	if len(tests) == 0 {
		fmt.Fprintf(stdout, "FAIL %s is empty: no *_test.moo files\n", label)
		return false
	}
	runDir := filepath.Join(root, "build", "run", name)
	unit := filepath.Join(runDir, "src")
	if err := os.RemoveAll(runDir); err != nil {
		fmt.Fprintf(stderr, "moorun: %v\n", err)
		return false
	}
	if err := os.MkdirAll(unit, 0o755); err != nil {
		fmt.Fprintf(stderr, "moorun: %v\n", err)
		return false
	}
	srcs, _ := filepath.Glob(filepath.Join(root, "src", "*.moo"))
	helpers, _ := filepath.Glob(filepath.Join(testDir, "*.moo"))
	for _, f := range append(srcs, helpers...) {
		if err := copyFile(f, filepath.Join(unit, filepath.Base(f))); err != nil {
			fmt.Fprintf(stderr, "moorun: %v\n", err)
			return false
		}
	}
	plants, _ := filepath.Glob(filepath.Join(testDir, "plant", "*"))
	for _, f := range plants {
		if err := copyFile(f, filepath.Join(runDir, filepath.Base(f))); err != nil {
			fmt.Fprintf(stderr, "moorun: %v\n", err)
			return false
		}
	}
	inputs, err := inputsModule(root, testDir)
	if err != nil {
		fmt.Fprintf(stdout, "FAIL %s: %v\n", label, err)
		return false
	}
	if err := os.WriteFile(filepath.Join(unit, "inputs.moo"), inputs, 0o644); err != nil {
		fmt.Fprintf(stderr, "moorun: %v\n", err)
		return false
	}
	if err := os.WriteFile(filepath.Join(unit, "_moorun.moo"), driver(tests), 0o644); err != nil {
		fmt.Fprintf(stderr, "moorun: %v\n", err)
		return false
	}

	cmd := exec.Command(moo, filepath.Join("src", "_moorun.moo"))
	cmd.Dir = runDir
	var out bytes.Buffer
	cmd.Stdout = io.MultiWriter(stdout, &out)
	cmd.Stderr = stderr
	runErr := cmd.Run()

	runs, passes, fails := 0, 0, 0
	for _, line := range strings.Split(out.String(), "\n") {
		switch {
		case strings.HasPrefix(line, "RUN Test"):
			runs++
		case strings.HasPrefix(line, "--- PASS Test"):
			passes++
		case strings.HasPrefix(line, "--- FAIL Test"):
			fails++
		}
	}
	switch {
	case runErr != nil:
		fmt.Fprintf(stdout, "FAIL %s: moo exited: %v\n", label, runErr)
		return false
	case runs == 0:
		fmt.Fprintf(stdout, "FAIL %s ran no Test functions\n", label)
		return false
	case fails != 0 || passes != runs:
		fmt.Fprintf(stdout, "FAIL %s: %d of %d tests failed\n", label, runs-passes, runs)
		return false
	}
	fmt.Fprintf(stdout, "ok %s %d passed\n", label, passes)
	return true
}

func copyFile(from, to string) error {
	b, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	return os.WriteFile(to, b, 0o644)
}

type input struct {
	key  string
	path string
}

// inputsModule is the moo source of inputs.moo (see the package comment).
func inputsModule(root, testDir string) ([]byte, error) {
	var files []input
	corpus, err := filepath.Glob(filepath.Join(root, "conformance", "*.txt"))
	if err != nil {
		return nil, err
	}
	sort.Strings(corpus)
	for _, f := range corpus {
		files = append(files, input{strings.TrimSuffix(filepath.Base(f), ".txt"), f})
	}
	controls, err := filepath.Glob(filepath.Join(root, "conformance-controls", "*.txt"))
	if err != nil {
		return nil, err
	}
	sort.Strings(controls)
	for _, f := range controls {
		files = append(files, input{"control_" + strings.TrimSuffix(filepath.Base(f), ".txt"), f})
	}
	if list, err := os.ReadFile(filepath.Join(testDir, "inputs.list")); err == nil {
		for _, line := range strings.Split(string(list), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if filepath.IsAbs(line) || strings.Contains(line, "..") {
				return nil, fmt.Errorf("inputs.list path %q must be relative to the repository and stay inside it", line)
			}
			p := filepath.Join(root, line)
			if _, err := os.Stat(p); err != nil {
				return nil, fmt.Errorf("inputs.list names %s, which is missing (make oracles writes build/oracle/)", line)
			}
			files = append(files, input{strings.TrimSuffix(filepath.Base(line), ".txt"), p})
		}
	}
	var b strings.Builder
	b.WriteString("--!strict\n-- inputs.moo, written by tools/moorun: input files as strings (DESIGN.md, \"The runner\")\nreturn table.freeze({\n")
	for _, f := range files {
		text, err := os.ReadFile(f.path)
		if err != nil {
			return nil, err
		}
		fmt.Fprintf(&b, "\t[\"%s\"] = \"", f.key)
		for _, c := range text {
			switch {
			case c == '\\' || c == '"':
				b.WriteByte('\\')
				b.WriteByte(c)
			case c == '\n':
				b.WriteString("\\n")
			case c >= 0x20 && c < 0x7f:
				b.WriteByte(c)
			default:
				fmt.Fprintf(&b, "\\x%02x", c)
			}
		}
		b.WriteString("\",\n")
	}
	b.WriteString("})\n")
	return []byte(b.String()), nil
}

// driver is the moo source of _moorun.moo: it requires every test module by a
// literal ./ path and runs its Test functions in sorted order.
func driver(tests []string) []byte {
	var b strings.Builder
	b.WriteString("-- _moorun.moo, written by tools/moorun (DESIGN.md, \"The runner\")\nlocal modules = {\n")
	for _, t := range tests {
		mod := strings.TrimSuffix(filepath.Base(t), ".moo")
		fmt.Fprintf(&b, "\t{ %q, require(\"./%s\") },\n", mod, mod)
	}
	b.WriteString(`}
for _, entry in modules do
	local mod = entry[2]
	if type(mod) ~= "table" then
		error("moorun: " .. entry[1] .. ".moo does not return a table of Test functions")
	end
	local names = {}
	for name, fn in mod do
		if type(name) == "string" and string.match(name, "^Test") and type(fn) == "function" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		print("RUN " .. name)
		local ok, err = pcall(mod[name])
		if ok then
			print("--- PASS " .. name)
		else
			print("--- FAIL " .. name)
			print("    " .. string.gsub(tostring(err), "\n", "\n    "))
		end
	end
end
`)
	return []byte(b.String())
}
