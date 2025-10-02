# title
  
Generate function calling Graph

# description

Generate function calling Graph:

- include all direct functions which call the specified function from $ARGUMENTS

- include all function chains with depth 8, originated from the specified
  function

- skip trivial or very simple functions or generic kernel APIs(such as,
  kmalloc, submit_bio, ...)

# motivation

- help to understand the context for calling the function

- help to understand the key and main exception paths

- help to understand what the function is doing

# requirements

- store the generated graph in png image format

- try to make the layout clean

- Color-coded by function importance and category

- add simple annotations for important involved functions, include Data Flow Diagram
and Critical Paths and main use contexts, save to another .txt file

