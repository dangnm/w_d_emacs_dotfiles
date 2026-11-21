Task: explain this whole file so a developer can read it from top to bottom, with the explanations running alongside the code.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}} (the whole file).{{truncated_note}}

Produce:
- summary: what this file is for and how it is organised, in a few sentences.
- sections: cover every line of code in the file, in order, from line {{target_start}} to line {{target_end}}. Blank lines between definitions do not need a section. Start with one section for the file header (module comment, requires, licence) if there is one. Then add one section per top-level definition (function, macro, variable, class, configuration block). Merge small neighbouring definitions into one section. Each section's source_start is the first line of the code it describes, and source_end is its last line. Use the absolute line numbers shown in the snapshot.
- Keep each explanation short: two to five sentences covering purpose, key logic, inputs and outputs, and side effects. The reader scrolls through every section, so brevity matters more than detail.
- dependencies: other files, functions or packages this file relies on that are visible in the code.
- data_flow: only when the file moves data between steps. Keep it to a few short lines.
- notes: anything unclear, or anything that needs checking in other files.

<source file="{{file}}">
{{snippet}}
</source>
