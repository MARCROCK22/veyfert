#!/usr/bin/env -S v

// Builds the complete programs in docs/*.md and README.md, every ```v block with a `fn main()`,
// and runs the blocks that are whole test files as tests. A full build, not `-check`, since
// `-check` misses some of veyfert's compile-time errors. Fragments are left alone, and so is
// docs/PLAN.md, a design document whose examples are sketches.
// Usage, from anywhere: v run tests/check_docs.vsh
import os

root := @VMODROOT
// The checkout is a folder named veyfert, so its parent goes on the module path.
vpath := '@vlib|@vmodules|${os.dir(root)}'
tmp := os.join_path(os.temp_dir(), 'veyfert_docs_check')
os.rmdir_all(tmp) or {}
mut files := os.ls(os.join_path(root, 'docs'))!.filter(it.ends_with('.md') && it != 'PLAN.md').map('docs/${it}')
files.sort()
files << 'README.md'
mut checked := 0
mut failed := 0
for file in files {
	lines := os.read_lines(os.join_path(root, file))!
	mut block := []string{}
	mut start := -1
	for i, line in lines {
		if start < 0 {
			if line.trim_space() == '```v' {
				start = i + 1
				block = []
			}
			continue
		}
		if line.trim_space() != '```' {
			block << line
			continue
		}
		code := block.join('\n')
		line_no := start + 1
		start = -1
		// A test block counts when it is a whole file, with its imports.
		is_test := code.contains('fn test_') && code.contains('\nimport ')
		if !is_test && !code.contains('fn main()') {
			continue
		}
		checked++
		work := os.join_path(tmp, '${os.file_name(file).all_before('.')}_${line_no}')
		os.mkdir_all(work)!
		path := os.join_path(work, if is_test { 'doc_test.v' } else { 'main.v' })
		os.write_file(path, code + '\n')!
		res := if is_test {
			os.exec([@VEXE, '-path', vpath, 'test', path])
		} else {
			os.exec([@VEXE, '-path', vpath, '-o', os.join_path(work, 'program'), path])
		}
		if res.exit_code != 0 {
			failed++
			eprintln('${file}:${line_no}:\n${res.output}')
		}
	}
}
println('docs: ${checked} programs built or tested, ${failed} failed')
if failed > 0 {
	exit(1)
}
