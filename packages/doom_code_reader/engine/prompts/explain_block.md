Task: explain a selected block of code.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Cursor line: {{point_line}}{{symbol_note}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

Explain the target block: what it accomplishes, step by step. Split it into logical sections (for example setup, decision, main work, result). For each section give the purpose, the logic, the inputs and outputs, dependencies and side effects. Every section needs valid source_start and source_end values taken from the snapshot, and they should stay inside the target block unless a nearby line is required to understand it.

<source file="{{file}}">
{{snippet}}
</source>
