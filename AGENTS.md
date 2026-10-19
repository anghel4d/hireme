
# Vocabulary

"Halt": means stop immediately and stash git work. 

"Wrap things up": means finish your running task *COMPLETELY* and do not start on new tasks. It does not mean "hard stop, halt, etc.

# Sacrosanct

Always fully quote the user's design decisions/explanations without paraphrasing.


# Big Workflows

- **Subagents:** When given 'ultracode' or other large agentic workflow tasks, unless otherwise specified by the user, your default behaviour should be to create a maximum of 6 workers who each get a lane and work through their tasks. They are never killed without explicit user approval. They can be cycled around for tasks. Consider them a team of EXPERTS, your own personal A-team. **NEVER** MAKE FABLE SUBAGENTS WITHOUT EXPRESS PERMISSION FROM THE USER.

- **Planning:** When working with subagents, don't overspecify. Instead, you should trust each of your workers judgements, giving them the prompts spoken by the user collated and directly, plus assigned slices and instructions to collaborate via message passing to one another. Building against a spec 1 order removed from my direct instructions is going to drift like a telephone game. Instead: the context summarizing (collating, verbatim with a bit of editorial to maek it fit) precisely what I asked for and said, the plan worked out with the user in the primary chat interface. 