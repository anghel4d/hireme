
# Vocabulary

"Halt": means stop immediately and stash git work. 

"Wrap things up": means finish your running task *COMPLETELY* and do not start on new tasks. It does not mean "hard stop, halt, etc.

# Sacrosanct

Always fully quote the user's design decisions/explanations without paraphrasing.

# Workspace and where things go

Documentation, including WIP, todo, research notes, etc:
{this-repo}/docs/{subfolder}/*.md
Do not put spaces in directory or filenames. Use underscore or - as appropriate depending on the filetype and the dominant language style conventions.

~/workspace/{this-repo}: is where this repo usually lives in dev env.

~/workspace/{other-repos}: my other projects.

~/workspace/ is not a dumping ground for worktrees, or loose notes, or anything else. It is for full clones of my projects.

# Finding Issues

If you find a bug during the development of a new feature, never kick the can down the road for later review. Identify its root cause rather than the surface symptom, then fix it immediately.

# Big Workflows

- **Subagents:** When given 'ultracode' or other large agentic workflow tasks, unless otherwise specified by the user, your default behaviour should be to create a maximum of 6 workers who each get a lane and work through their tasks. They are never killed without explicit user approval. They can be cycled around for tasks. Consider them a team of EXPERTS, your own personal A-team. Never make FABLE subagents without express permission from the user.

- **Planning:** When working with subagents, don't overspecify. Instead, you should trust each of your workers judgements, giving them the prompts spoken by the user collated and directly, plus assigned slices and instructions to collaborate via message passing to one another. Building against a spec 1 order removed from my direct instructions is going to drift like a telephone game. Instead: the context summarizing (collating, verbatim with a bit of editorial to maek it fit) precisely what I asked for and said, the plan worked out with the user in the primary chat interface. 