#!/usr/bin/env -S v

// Compiles each case in tests/compile_fail and checks that it fails with the message its
// `// expect:` line names. Run it from anywhere: v run tests/compile_fail.vsh
import os

root := os.dir(os.dir(@FILE))
vpath := '@vlib|@vmodules|${os.dir(root)}'
out := os.join_path(os.temp_dir(), 'veyfert_compile_fail')
mut failed := 0
for file in os.walk_ext(os.join_path(root, 'tests', 'compile_fail'), '.v') {
	lines := os.read_lines(file)!
	expect := lines[0].all_after('// expect: ')
	// A full build: `-check` skips the generic instantiations that run `$compile_error`.
	res := os.exec([@VEXE, '-path', vpath, '-o', out, file])
	if res.exit_code == 0 || !res.output.contains(expect) {
		eprintln('FAIL ${os.file_name(file)}: expected an error with `${expect}`, got:\n${res.output}')
		failed++
	} else {
		println('ok   ${os.file_name(file)}')
	}
}
if failed > 0 {
	exit(1)
}
