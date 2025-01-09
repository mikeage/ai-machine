# Getting started with local LLMs

## Run the script to set up an AWS EC2. Follow the instructions. Enjoy.

No, seriously. Just run the script.

## Running on a local Mac (M1/M2/M3 only, 8GB+)

```bash
brew install uv  # pip/pipx replacement, optional, but crazy fast.
brew install ollama  # Runs the models locally
brew services start ollama  # Always run ollama in the background (uses 0 CPU and minimal RAM when you don't do anything)
uv tool install llm  # Install the CLI
llm install llm-ollama  # Plugin to let llm talk to ollama
ollama pull llama3.2  # A good model to start with
ollama pull gemma2  # An alternative model
llm -m llama3.2 'Tell me a joke about penguins'
```

## Links

* http://llm.datasette.io/en/stable/ -- the command line we use
* https://ollama.com -- Runs models locally
