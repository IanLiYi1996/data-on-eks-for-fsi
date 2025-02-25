import aiohttp
import asyncio
import os
import time
import logging

# Setup logging configuration
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Constants for model endpoint and service name
model_endpoint = os.getenv("MODEL_ENDPOINT", "/vllm")
service_name = os.getenv("SERVICE_NAME", "http://localhost:8000")

# Function to count tokens in a response
def count_tokens(text):
    return len(text.split())

# Function to generate text asynchronously
async def generate_text(session, prompt):
    SYSTEM_PROMPT = """<<SYS>>\nKeep short answers of no more than 100 sentences.\n<</SYS>>\n\n"""
    payload = {
        "input": SYSTEM_PROMPT + prompt,
        "parameters": {
            "max_new_tokens": 512,
            "temperature": 0.01,
            "top_p": 1,
            "top_k": 20,
            "stop_sequences": None
        }
    }
    url = f"{service_name}{model_endpoint}"

    try:
        start_time = time.perf_counter()
        async with session.post(url, json=payload, timeout=180) as response:
            end_time = time.perf_counter()
            latency = end_time - start_time

            logger.info(f"Response status: {response.status}")

            if response.status == 200:
                response_data = await response.json()
                text = response_data.get("generated_text", "").strip()
                if not text:
                    logger.error("No generated text found in response.")
                    return None, latency, 0

                num_tokens = count_tokens(text)
                return text, latency, num_tokens
            else:
                logger.error(f"Failed to get response. Status code: {response.status}")
                logger.error(f"Error message: {await response.text()}")
                return None, latency, 0
    except aiohttp.ClientError as e:
        logger.error(f"Request exception: {str(e)}")
        return None, None, 0

# Function to warm up the model
async def warmup(session):
    """Warm up the model to reduce cold start latency."""
    payload = {
        "input": "Warmup",
        "parameters": {
            "max_new_tokens": 1,
            "temperature": 0.7,
            "top_p": 0.9,
            "top_k": 50
        }
    }
    url = f"{service_name}{model_endpoint}"

    try:
        async with session.post(url, json=payload, timeout=180) as response:
            if response.status == 200:
                logger.info("Warm-up successful")
            else:
                logger.error(f"Warm-up failed. Status code: {response.status}")
                logger.error(f"Error message: {await response.text()}")
    except aiohttp.ClientError as e:
        logger.error(f"Warm-up request exception: {str(e)}")

# Function to read prompts from a file
def read_prompts(file_path):
    with open(file_path, 'r') as file:
        return [line.strip() for line in file.readlines()]

# Function to write results to a file
def write_results(file_path, results, summary):
    with open(file_path, 'w') as file:
        for result in results:
            prompt, latency, response_text, num_tokens = result
            file.write(f"Prompt: {prompt}\n")
            file.write(f"Response Time: {latency:.2f} seconds\n")
            file.write(f"Token Length: {num_tokens}\n")
            file.write(f"Response: {response_text}\n")
            file.write("=" * 80 + "\n")

        file.write("\nSummary of Latency:\n")
        file.write(f"Total Prompts: {len(results)}\n")
        file.write(f"Average Latency: {summary['average_latency']:.2f} seconds\n")
        file.write(f"Max Latency: {summary['max_latency']:.2f} seconds\n")
        file.write(f"Min Latency: {summary['min_latency']:.2f} seconds\n")

# Main function to handle asynchronous execution
async def main():
    prompts = read_prompts('prompts.txt')
    results = []

    total_latency = 0
    max_latency = float('-inf')
    min_latency = float('inf')

    async with aiohttp.ClientSession() as session:
        await warmup(session)
        tasks = [generate_text(session, prompt) for prompt in prompts]
        responses = await asyncio.gather(*tasks)

        for prompt, (response_text, latency, num_tokens) in zip(prompts, responses):
            if latency is not None:
                results.append([prompt, latency, response_text, num_tokens])
                total_latency += latency
                max_latency = max(max_latency, latency)
                min_latency = min(min_latency, latency)
            else:
                results.append([prompt, "N/A", response_text, 0])

    valid_latencies = [r[1] for r in results if isinstance(r[1], float)]
    if valid_latencies:
        summary = {
            'average_latency': sum(valid_latencies) / len(valid_latencies),
            'max_latency': max(valid_latencies),
            'min_latency': min(valid_latencies)
        }
        write_results('results.txt', results, summary)

# Run the main function
if __name__ == "__main__":
    asyncio.run(main())
