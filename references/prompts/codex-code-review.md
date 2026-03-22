Review the uncommitted changes in this repository. Focus on:
- Correctness: logic errors, off-by-one, null handling
- Security: injection, hardcoded secrets, unsafe operations
- Consistency: does the code follow existing patterns in the codebase

You MUST respond with ONLY a JSON object:
{"verdict":"approve","issues":[],"suggestions":[]}

Rules:
- verdict: "approve" if no blocking issues, "revise" if there are issues that must be fixed
- issues: blocking problems
- suggestions: non-blocking improvements
