---
name: foundation-models-cli
description: Use foundation-models-cli to interact with Apple's on-device LLM via the FoundationModels framework. This skill should be used when the user wants to send prompts to the local Apple Intelligence model, get structured JSON output from the on-device LLM, or test prompts with various generation options like temperature and streaming.
---

# foundation-models-cli

A Swift CLI tool that sends prompts to the on-device LLM using Apple's FoundationModels framework. Requires macOS 26+ and an Apple Intelligence capable device (M-series chip).

## Installation

```bash
git clone https://github.com/akiym/foundation-models-cli.git
cd foundation-models-cli
swift build -c release
cp .build/release/foundation-models-cli /usr/local/bin/
```

## Usage

```
foundation-models-cli <prompt> [options]
```

### Options

| Option | Short | Description |
|---|---|---|
| `--instructions <text>` | `-i` | System instructions to guide the model |
| `--temperature <value>` | `-t` | Generation temperature from 0.0 to 2.0 |
| `--max-tokens <count>` | `-m` | Maximum response token count |
| `--greedy` | | Use greedy sampling for deterministic output |
| `--stream` | `-s` | Enable streaming output |
| `--field <spec>` | `-f` | Structured output field in `name:Type:description` format. Can be repeated. |

### Supported types for `--field`

`String`, `Int`, `Double`, `Bool`, `[String]`, `[Int]`, `[Double]`, `[Bool]`

## Examples

### Plain text output

```bash
foundation-models-cli "Explain Swift concurrency in 3 sentences"
```

### With system instructions and temperature

```bash
foundation-models-cli "Write a haiku about programming" -i "You are a creative poet" -t 1.5
```

### Streaming output

```bash
foundation-models-cli "Tell me a short story" -s -m 200
```

### Structured JSON output with Guided Generation

Use `-f` to define output fields. The model uses Apple's Guided Generation to ensure the output conforms to the schema.

```bash
foundation-models-cli "Review the movie Inception" \
  -f "title:String:The movie title" \
  -f "rating:Int:Rating from 1 to 5" \
  -f "summary:String:A short review summary"
```

Output:

```json
{
  "rating": 5,
  "summary": "A mind-bending masterpiece about dreams within dreams.",
  "title": "Inception"
}
```

### Array types in structured output

```bash
foundation-models-cli "List 3 popular Japanese dishes" \
  -f "dishes:[String]:List of dish names" \
  -f "descriptions:[String]:Brief description of each dish"
```

## Guidelines

- Always quote the prompt argument to avoid shell interpretation issues
- Use `--max-tokens` to prevent repetitive generation on open-ended prompts
- `--stream` and `--field` cannot be used together
- The on-device model has a 4096 token context window; keep prompts concise
- For deterministic output, use `--greedy`
- Structured output uses `DynamicGenerationSchema` for type-safe Guided Generation
