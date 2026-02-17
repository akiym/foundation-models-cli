# foundation-models-cli

A simple CLI that sends prompts to the on-device LLM using Apple's FoundationModels framework.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later
- Apple Intelligence capable device (M-series chip)

## Build

```
swift build -c release
```

## Usage

```
foundation-models-cli <prompt> [options]
```

### Options

| Option | Short | Description |
|---|---|---|
| `--instructions` | `-i` | System instructions |
| `--temperature` | `-t` | Generation temperature (0.0–2.0) |
| `--max-tokens` | `-m` | Maximum response token count |
| `--greedy` | | Use greedy sampling (deterministic output) |
| `--stream` | `-s` | Enable streaming output |
| `--field` | `-f` | Structured output field (`name:Type:description`) |

Supported types for `--field`: `String`, `Int`, `Double`, `Bool`, `[String]`, `[Int]`, `[Double]`, `[Bool]`

### Examples

```
# Basic usage
foundation-models-cli "Hello"

# With system instructions
foundation-models-cli "Explain Swift concurrency" -i "You are a helpful programming tutor"

# Streaming output with temperature and max tokens
foundation-models-cli "Write a creative poem" -t 1.5 -m 200 -s

# Structured output with Guided Generation
foundation-models-cli "Review Inception" \
  -f "title:String:The movie title" \
  -f "rating:Int:Rating from 1 to 5" \
  -f "summary:String:A short review"

# Array types
foundation-models-cli "List 3 Japanese dishes" \
  -f "dishes:[String]:List of dish names" \
  -f "count:Int:Number of dishes"
```
