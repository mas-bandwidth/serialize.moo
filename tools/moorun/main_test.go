// Unit tests of -corpus and -controls: inputsModule reads the vendored corpus
// by default and only the named directories when they are set, and run refuses,
// by name, one that is not a directory. No moo, no time, no network; the
// fixtures live under the repository's build/, never outside it.
package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture makes a scratch repository root under build/ holding a vendored
// conformance/vendored.txt and conformance-controls/vendored.expected, and a
// separate corpus (override.txt) and controls directory (override.expected).
func fixture(t *testing.T) (root, corpus, controls string) {
	t.Helper()
	base := filepath.Join("..", "..", "build")
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp(base, "moorun-test.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	root = filepath.Join(dir, "repo")
	corpus = filepath.Join(dir, "corpus")
	controls = filepath.Join(dir, "controls")
	files := map[string]string{
		filepath.Join(root, "conformance", "vendored.txt"):               "vendored\n",
		filepath.Join(root, "conformance-controls", "vendored.expected"): "vendored\n",
		filepath.Join(corpus, "override.txt"):                            "override\n",
		filepath.Join(controls, "override.expected"):                     "override\n",
	}
	for p, text := range files {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root, corpus, controls
}

func setDirs(t *testing.T, corpus, controls string) {
	t.Helper()
	corpusDir, controlsDir = corpus, controls
	t.Cleanup(func() { corpusDir, controlsDir = "", "" })
}

func TestCorpusDefaultIsVendored(t *testing.T) {
	root, _, _ := fixture(t)
	setDirs(t, "", "")
	m, err := inputsModule(root, filepath.Join(root, "test", "none"), "")
	if err != nil {
		t.Fatal(err)
	}
	s := string(m)
	for _, key := range []string{`["vendored"]`, `["expected_vendored"]`} {
		if !strings.Contains(s, key) {
			t.Errorf("default: inputs.moo has no %s", key)
		}
	}
	if strings.Contains(s, "override") {
		t.Errorf("default: inputs.moo carries the override corpus")
	}
}

func TestCorpusOverrideIsTheOnlyCorpus(t *testing.T) {
	root, corpus, controls := fixture(t)
	setDirs(t, corpus, controls)
	m, err := inputsModule(root, filepath.Join(root, "test", "none"), "")
	if err != nil {
		t.Fatal(err)
	}
	s := string(m)
	for _, key := range []string{`["override"]`, `["expected_override"]`} {
		if !strings.Contains(s, key) {
			t.Errorf("override: inputs.moo has no %s", key)
		}
	}
	if strings.Contains(s, "vendored") {
		t.Errorf("override: inputs.moo carries the vendored corpus beside the override")
	}
}

func TestCorpusOverrideNotADirectoryIsRefused(t *testing.T) {
	root, corpus, controls := fixture(t)
	for _, c := range []struct{ flag, corpus, controls, missing string }{
		{"-corpus", filepath.Join(corpus, "missing"), controls, filepath.Join(corpus, "missing")},
		{"-controls", corpus, filepath.Join(controls, "missing"), filepath.Join(controls, "missing")},
	} {
		setDirs(t, c.corpus, c.controls)
		var out, errOut bytes.Buffer
		if code := run(root, nil, &out, &errOut); code == 0 {
			t.Errorf("%s naming no directory: run exited 0", c.flag)
		}
		want := "FAIL " + c.flag + " " + c.missing + " is not a directory"
		if !strings.Contains(out.String(), want) {
			t.Errorf("%s naming no directory: output %q does not say %q", c.flag, out.String(), want)
		}
	}
}

// -extra joins an ordinary run and never a control run: a control names
// exactly the vectors its sabotaged reader must fail, so a generated file
// beside the corpus would trip it.
func TestExtraDirJoinsOrdinaryRunsOnly(t *testing.T) {
	root, _, _ := fixture(t)
	setDirs(t, "", "")
	extra := t.TempDir()
	if err := os.WriteFile(filepath.Join(extra, "diff.txt"), []byte("generated\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	extraDir = extra
	t.Cleanup(func() { extraDir = "" })
	ordinary, err := inputsModule(root, filepath.Join(root, "test", "none"), "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ordinary), `["diff"]`) {
		t.Errorf("an ordinary run does not carry the -extra file")
	}
	control, err := inputsModule(root, filepath.Join(root, "test", "none"), "some-rule")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(control), "diff") {
		t.Errorf("a control run carries the -extra file")
	}
	if err := os.WriteFile(filepath.Join(extra, "vendored.txt"), []byte("clash\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := inputsModule(root, filepath.Join(root, "test", "none"), ""); err == nil {
		t.Errorf("an -extra file named like a corpus file was accepted")
	}
	extraDir = filepath.Join(extra, "missing")
	var out, errOut bytes.Buffer
	if code := run(root, nil, &out, &errOut); code == 0 {
		t.Errorf("-extra naming no directory: run exited 0")
	}
}
