package tree_sitter_bend2_test

import (
	"testing"

	tree_sitter_bend2 "github.com/soulthym/tree-sitter-bend2/bindings/go"
	tree_sitter "github.com/tree-sitter/go-tree-sitter"
)

func TestCanLoadGrammar(t *testing.T) {
	parser := tree_sitter.NewParser()
	defer parser.Close()
	if err := parser.SetLanguage(tree_sitter.NewLanguage(tree_sitter_bend2.Language())); err != nil {
		t.Fatalf("Error loading Bend2 grammar: %v", err)
	}
	tree := parser.Parse([]byte("def f() -> U32: 42\n"), nil)
	if tree == nil {
		t.Fatal("Error parsing Bend2 source")
	}
	defer tree.Close()
	if tree.RootNode().HasError() {
		t.Fatalf("Valid Bend2 source rejected: %s", tree.RootNode().ToSexp())
	}
}
