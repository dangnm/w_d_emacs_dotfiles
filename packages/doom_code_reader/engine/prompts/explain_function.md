Task: explain a function, including its purpose, logic, parameters, return values, dependencies and side effects.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Function: {{symbol}}
Cursor line: {{point_line}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

Explain the function in logical sections such as signature and parameters, main logic, branches and error handling, and return value or side effects. Name the parameters and return values as they appear in the code. Mention dependencies only when they are visible in the code or in files you verified with Read or Grep. Every section needs valid source_start and source_end values taken from the snapshot.

<source file="{{file}}">
{{snippet}}
</source>
