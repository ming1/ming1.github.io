# title
  
Generate function calling Graph

# description

Generate function calling Graph:

- include all direct functions which call the specified function from $ARGUMENTS

- include all function chains with depth 6, originated from the specified
  function

- skip trivial or very simple functions or generic external APIs(such as,
  in linux kernel, kmalloc, submit_bio, spin_unlock can be skipped)

# motivation

- help to understand the context for calling the function

- help to understand what the function is doing

# requirements

- store the generated graph in png image format

- try to make the layout clean

- keep the layout browsable from web browser, don't make it too wide

- Color-coded by function importance and category

- add simple notes for important involved functions, include Data Flow Diagram
and main use contexts, save to another .txt file; do not annotate external
APIs; make this note file short and easy to follow the top idea for
involved functions
