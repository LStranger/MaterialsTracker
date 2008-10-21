MATERIALSTRACKER_VERSION = "30000.01";
MATERIALSTRACKER_DB_VERSION = 20001;

--runtime variables
local MTracker_BankIsOpen = false;
local MTracker_GuildBankIsOpen = false;
local MTracker_MailboxIsOpen = false;
local MTracker_MailUpdatesInProgress = false;
local MTracker_CurrentPlayer = {};
local MTracker_NUMBER_OF_BAG_SLOTS = 4;
local MTracker_UseTooltips=true;
local MTracker_LastMailScan=0;
local MTracker_MailScanInterval=60;	--time in seconds between mail scans.  appears the UI only retrieves mail from the server every 60 seconds.

--debug levels
local mt_TRACE=2;
local mt_INFO=1;

MTracker = AceLibrary("AceAddon-2.0"):new("AceConsole-2.0", "AceEvent-2.0", "AceDB-2.0", "AceDebug-2.0");
MTracker:RegisterDB("MaterialsTracker_Materials", "MaterialsTracker_PlayerConfig");
MTracker:RegisterDefaults("account", {
    materials = {
	['*'] = {
		tracked=false,
		ByPlayer = {
			['*'] = {	--realm
				['*'] = {	--playername
					NbInMail=0,
					NbInBank=0,
					NbInBag=0,
				},
			},
		},
		ByGuild = {
			['*'] = {	--realm
				['*'] = {	--guild
					['*'] = {	--tabname
						NbInGBank=0,
					}
				},
			},
		},
		UsedIn = {
			['*'] = false,
		},
	},
    },
    players = {},
    config = {
	DBVersion=0,   
    },
} )

function MTracker:OnInitialize()
	--Setup our chat command interface
	self:RegisterChatCommand({"/mtracker"},
		{
			type = "group",
			args = {
				resetdata = {
					type = "execute",
					name = "reset to the default config",
					desc = "reset",
			    	      	func = function() self:ResetDB(); end,
				},
				tooltips = {
					type = "execute",
					name = "reset to the default config",
					desc = "reset",
			    	      	func = function() self:UseTooltips_Update(); end,
				},
				item = {
					type = "text",
					name = "item",
					desc = "list item counts",
					usage = "<itemlink>",
					get = false,
			    	      	set = function(v) self:ShowCountsInChat(v); end,
				},
				additem = {
					type = "text",
					name = "additem",
					desc = "add an item to the database",
					usage = "<itemlink>",
					get = false,
			    	      	set = function(v) self:AddItem(v); end,
				},
				debugLevel = {
					type = "text",
					name = "debugLevel",
					desc = "change debug level.  1=INFO, 2=TRACE",
					usage = "<level>",
					get = false,
			    	      	set = function(v) self:SetDebugLevel(tonumber(v)); end,
				},
			}
		},
		"MATERIALSTRACKER"
	);
	
	if (not self.db.account.materials) then
		self:Print("creating materials table");
		self.db.account.materials={};
	end

	MTracker_CurrentPlayer = {UnitName("player"), GetCVar("realmName")};
	self:CheckDatabaseVersion();
end

function MTracker:OnEnable()
	self:SetDebugging(false);

	-- Hook in new tooltip code
	if (IsAddOnLoaded("EnhTooltip") and IsAddOnLoaded("Stubby")) then
		Stubby.RegisterFunctionHook("EnhTooltip.AddTooltip", 500, MTracker_HookTooltip)
	end

	-- events
	self:RegisterOurEvents();
	------------------

	self:AddUserToPlayerTable();
end

function MTracker:AddUserToPlayerTable()
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];
	
	--create the realm table if it does not yet exist.
	if (not self.db.account.players[realmName]) then
		self.db.account.players[realmName]={};
	end
	if (not self.db.account.players[realmName][playerName]) then
		self.db.account.players[realmName][playerName]=1;
	end
end

function MTracker:RegisterOurEvents()
	self:RegisterEvent("BAG_UPDATE", "UpdateNumberInBag");
	self:RegisterEvent("TRADE_SKILL_SHOW", "UpdateTradeSkillsSavedMaterials");
	self:RegisterEvent("BANKFRAME_OPENED", "BankIsOpened");
	self:RegisterEvent("BANKFRAME_CLOSED", "BankIsClosed");
	self:RegisterEvent("MAIL_SHOW", "MailboxIsOpened");
	self:RegisterEvent("MAIL_CLOSED", "MailboxIsClosed");
	self:RegisterEvent("MAIL_INBOX_UPDATE", "MailInboxUpdate");
	self:RegisterEvent("GUILDBANKFRAME_OPENED", "GuildBankIsOpened");
	self:RegisterEvent("GUILDBANKFRAME_CLOSED", "GuildBankIsClosed");
	self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", "UpdateNumberInGuildBank");
end

function MTracker:BankIsOpened()
	MTracker_BankIsOpen = true;
	self:UpdateNumberInBank();
end
function MTracker:BankIsClosed()
	MTracker_BankIsOpen = false;
end

function MTracker:MailboxIsOpened()
	MTracker_MailboxIsOpen = true;
end
function MTracker:MailboxIsClosed()
	MTracker_MailboxIsOpen = false;
end
function MTracker:MailInboxUpdate()
	if ((GetTime()-MTracker_LastMailScan) > MTracker_MailScanInterval) then
		self:UpdateNumberInMailbox();
	end
end

function MTracker:GuildBankIsOpened()
	MTracker_GuildBankIsOpen = true;
--	self:UpdateNumberInGuildBank();
end
function MTracker:GuildBankIsClosed()
	MTracker_GuildBankIsOpen = false;
end

function MTracker:UpdateTradeSkillsSavedMaterials()
	self:LevelDebug(mt_TRACE, "MTracker:UpdateTradeSkillsSavedMaterials enter");

	local tradeSkill = GetTradeSkillLine();
	self:LevelDebug(mt_TRACE, "MTracker:UpdateTradeSkillsSavedMaterials tradeSkill opened is "..isNullOrValue(tradeSkill));

	--TODO: create table in localization file and check that tradeSkill is in there.
	if (tradeSkill~=nil) then
		self:UpdateTradeSkillSavedMaterials(tradeSkill);
	end
end

function MTracker:UpdateNumberInMailbox()
	self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInMailbox enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	-- if MTracker_MailUpdatesInProgress==true, don't process again, we are already doing it.
	-- hoping to fix hard locking issue i am experiencing.
	if (MTracker_MailboxIsOpen and not MTracker_MailUpdatesInProgress) then
--		self:Print("Materials Tracker: Scanning inbox for items");
	
		--set the lock, we only want to process the update once.
		MTracker_MailUpdatesInProgress=true;
		MTracker_LastMailScan=GetTime();	--GetTime is seconds that my computer has been running.

		self:ResetMailboxCount();
				
		local nbr = GetInboxNumItems();
		for mailItem=1, nbr, 1 do
			for attachment=1, ATTACHMENTS_MAX_RECEIVE, 1 do
				local name, itemTexture, count, quality, canUse = GetInboxItem(mailItem, attachment);
				self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInMailbox itemName is "..isNullOrValue(name));

				if (name~= nil) then
					local code = self:getCodeFromName(name);
					if (code and self.db.account.materials[code].tracked) then
						self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInMailbox code is "..isNullOrValue(code));
						self.db.account.materials[code].ByPlayer[realmName][playerName].NbInMail = 
							(count + self.db.account.materials[code].ByPlayer[realmName][playerName].NbInMail);
					end
				end
			end
		end
		--unlock it when we are done.
		MTracker_MailUpdatesInProgress=false;
	end
end

function MTracker:UpdateNumberInBag()
	self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBag enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	--reset bag count for this player
	self:ResetBagCount();

	for bag=0, MTracker_NUMBER_OF_BAG_SLOTS, 1 do
		for slot=1, GetContainerNumSlots(bag), 1 do
			local itemLink = GetContainerItemLink(bag,slot);
			if(itemLink) then	--bag slot is empty.
--				local itemName = self:NameFromLink(itemLink);
--				local code = self:CodeFromLink(itemLink);	--the code is the key to the material

				local code, itemName = self:GetNACFromLink(itemLink);

				self:LevelDebug(mt_TRACE, "MTracker_UpdateNumberInBag itemName is "..isNullOrValue(itemName));
				self:LevelDebug(mt_TRACE, "MTracker_UpdateNumberInBag code is "..isNullOrValue(code));

				if (code and self.db.account.materials[code].tracked) then
					local texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag,slot);
					self.db.account.materials[code].ByPlayer[realmName][playerName].NbInBag = 
						(itemCount + self.db.account.materials[code].ByPlayer[realmName][playerName].NbInBag);
				end
			end
		end
	end	
	--call bank and mail update, incase the user is currently moving things between the bag and bank, or retrieving mail
	self:UpdateNumberInBank();
	self:UpdateNumberInMailbox();
end

function MTracker:UpdateNumberInBank()
	self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if MTracker_BankIsOpen then
		self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank bank frame is open");
		self:ResetBankCount();

		--as of 2.00.  
		--container -1 is main bank
		--containers 0-4 are normal inventory bags
		--containers 5-11 are bank bags

		--there are now 7 bank bag slots
		--there are 28 generic bank slots
		--GetNumBankSlots()   - Returns total purchased bank bag slots, and a flag indicating if it's full.
		for container=-1, (GetNumBankSlots()+4), 1 do
			if (container >= 0 and container<5) then 
				--do nothing, just skip these since they are not bank bags.
			else
				for slot=1, GetContainerNumSlots(container), 1 do
					self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank slot,container is "..slot..","..container);
					local itemLink = GetContainerItemLink(container,slot)
					self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank itemLink is "..isNullOrValue(itemLink));
					if(itemLink) then	-- slot is empty.
--						local itemName = self:NameFromLink(itemLink);
--						local code = self:CodeFromLink(itemLink);	--this is the key to the material

						local code, itemName = self:GetNACFromLink(itemLink);

						if (code and self.db.account.materials[code].tracked) then
							local texture, itemCount, locked, quality, readable = GetContainerItemInfo(container,slot);
							self.db.account.materials[code].ByPlayer[realmName][playerName].NbInBank = 
								(itemCount + self.db.account.materials[code].ByPlayer[realmName][playerName].NbInBank);
						end
					end
				end
			end
		end
	end
end

--	["ByGuild"] = {
--		["realm"] = {
--			["guild"] = {
--				["tab1"] = {
--					["NbInGBank"] = 9,
--				}
--				["tab2"] = {
--					["NbInGBank"] = 9,
--				}
--			},
--		},
--	},

function MTracker:UpdateNumberInGuildBank()
	self:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInGuildBank enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];
	local guildName = GetGuildInfo("player");

	if (guildName~=nil) then
		if (MTracker_GuildBankIsOpen and GuildBankFrame.mode == "bank") then
			local tab = GetCurrentGuildBankTab();
			local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(tab);
			self:ResetGBankCount(realmName, guildName,tab);
			for i=1, MAX_GUILDBANK_SLOTS_PER_TAB do				--currently 98
				index = mod(i, NUM_SLOTS_PER_GUILDBANK_GROUP);		--currently 14
				if ( index == 0 ) then
					index = NUM_SLOTS_PER_GUILDBANK_GROUP;
				end
				local texture, itemCount, locked = GetGuildBankItemInfo(tab, i);
				local itemLink = GetGuildBankItemLink(tab, i);
				local code, itemName = self:GetNACFromLink(itemLink);
				if (code and self.db.account.materials[code].tracked) then
					self.db.account.materials[code].ByGuild[realmName][guildName][tab].NbInGBank = 
						(itemCount + self.db.account.materials[code].ByGuild[realmName][guildName][tab].NbInGBank);
				end
			end
		end
	end
end

function MTracker:ResetBagCount() 
	self:LevelDebug(mt_TRACE, "MTracker:ResetBagCount enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for k,v in pairs(self.db.account.materials) do
		self:LevelDebug(mt_TRACE, "key is "..k);
		self.db.account.materials[k].ByPlayer[realmName][playerName].NbInBag=0;
	end
end

function MTracker:ResetBankCount() 
	self:LevelDebug(mt_TRACE, "MTracker:ResetBankCount enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for k,v in pairs(self.db.account.materials) do
		self:LevelDebug(mt_TRACE, "key is "..k);
		self.db.account.materials[k].ByPlayer[realmName][playerName].NbInBank=0;
	end
end
function MTracker:ResetMailboxCount() 
	self:LevelDebug(mt_TRACE, "MTracker:ResetMailboxCount enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for k,v in pairs(self.db.account.materials) do
		self:LevelDebug(mt_TRACE, "key is "..k);
		self.db.account.materials[k].ByPlayer[realmName][playerName].NbInMail=0;
	end
end
function MTracker:ResetGBankCount(realmName, guildName,tab)
	self:LevelDebug(mt_TRACE, "MTracker:ResetGBankCount enter");
--	local playerName = MTracker_CurrentPlayer[1];
--	local realmName = MTracker_CurrentPlayer[2];
--	local guildName = GetGuildInfo("player");

	for k,v in pairs(self.db.account.materials) do
		self:LevelDebug(mt_TRACE, "key is "..k);
		self.db.account.materials[k].ByGuild[realmName][guildName][tab].NbInGBank=0;
	end
end
function MTracker:getLinkFromName(name)
	if (name==nil) then return end;

	for key,value in pairs(self.db.account.materials) do 
		if (self.db.account.materials[key].Name == name) then
			return self.db.account.materials[key].Link;
		end
	end
	return nil;
end
function MTracker:getCodeFromName(name)
	if (name==nil) then return end;

	for key,value in pairs(self.db.account.materials) do 
		if (self.db.account.materials[key].Name == name) then
			return key;
		end
	end
	return nil;
end

function MTracker:AddProfessionNameToMaterial(itemCode, professionName) 
	self:LevelDebug(mt_TRACE, "MTracker:AddProfessionNameToMaterial enter");
	self:LevelDebug(mt_TRACE, "adding "..isNullOrValue(professionName).." to "..isNullOrValue(itemCode));

	self.db.account.materials[itemCode].UsedIn[professionName]=true;
end


function MTracker:UpdateTradeSkillSavedMaterials(tradeSkillName)
	self:LevelDebug(mt_TRACE, "MTracker:UpdateTradeSkillSavedMaterials enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for i=1, GetNumTradeSkills(), 1 do
		--skillType is either "header", if the skillIndex references to a heading, or a string indicating the difficulty to craft the item ("trivial", "easy" (?), "optimal", "difficult").
		local skillName, skillType, numAvailable, isExpanded = GetTradeSkillInfo(i)
		self:LevelDebug(mt_TRACE, "skillName is "..isNullOrValue(skillName));
		
		if (skillType ~="header") then
			for j=1, GetTradeSkillNumReagents(i), 1 do
				local reagentName, reagentTexture, reagentCount, playerReagentCount = GetTradeSkillReagentInfo(i, j);
				self:LevelDebug(mt_TRACE, "reagentName is "..isNullOrValue(reagentName));
				local reagentlink = GetTradeSkillReagentItemLink(i,j);
				local code = self:CodeFromLink(reagentlink);
				self:LevelDebug(mt_TRACE, "code is "..isNullOrValue(code));
	
				if (code) then
					self.db.account.materials[code].Texture = reagentTexture;
					self.db.account.materials[code].Link = reagentlink;
					self.db.account.materials[code].Name = reagentName;
					self.db.account.materials[code].tracked = true;
					self:AddProfessionNameToMaterial(code, tradeSkillName);
				end
			end
		end		
	end
--	self.db.account.config.DBVersion = MATERIALSTRACKER_DB_VERSION;
end

function MTracker:ItemBeingTracked(code) 
	return self.db.account.materials[code].tracked;
end

function MTracker:getUsedIn(code) 
	return self.db.account.materials[code].UsedIn;
end


function MTracker_HookTooltip(funcVars, retVal, frame, name, link, quality, count)
	if (MTracker_UseTooltips) then
--		local code = MTracker:CodeFromLink(link);
--		local iName = GetItemInfo(link);

		local code, iName = MTracker:GetNACFromLink(link);
		if (code and MTracker:ItemBeingTracked(code)) then	--checks if the code is valid, and also if the code is found in the mtracker database.
			local nbInBag, nbInBank, nbInReroll, nbInMail, nbInGuild = MTracker:getMaterialCounts(code);
--			local price = MTracker_getMaterialDefaultPrice(code);

			EnhTooltip.AddSeparator()
			EnhTooltip.AddLine("MaterialTracker Info"..":", nil, false);
			EnhTooltip.LineColor(0,1,1);
			EnhTooltip.AddLine("In Bags"..": "..nbInBag, nil, false);
			EnhTooltip.LineColor(1,0.3,1);
			EnhTooltip.AddLine("In Bank"..": "..nbInBank, nil, false);
			EnhTooltip.LineColor(1,0.3,1);
			EnhTooltip.AddLine("In Mail"..": "..nbInMail, nil, false);
			EnhTooltip.LineColor(1,0.3,1);
			EnhTooltip.AddLine("On Toons"..": "..nbInReroll, nil, false);
			EnhTooltip.LineColor(1,0.3,1);
			EnhTooltip.AddLine("In Guild"..": "..nbInGuild, nil, false);
			EnhTooltip.LineColor(1,0.3,1);

			--add used-in information
			EnhTooltip.AddLine("Used By"..": "..MTracker:BuildUsedInString(MTracker:getUsedIn(code)), nil, false);
			EnhTooltip.LineColor(1,0.3,1);

--			EnhTooltip.AddLine("Cost"..": "..ESell_Money_getStringFormatWithColor(priceUnite), nil, false);
--			EnhTooltip.LineColor(1,0.3,1);
		end
	end
end

function MTracker:BuildUsedInString(UsedIntable) 
	self:LevelDebug(mt_TRACE, "MTracker:BuildUsedInString enter");
	local usedInString="";
	if (UsedIntable) then
		for profession, value in pairs(UsedIntable) do
			if (value) then 
				usedInString = usedInString.." "..profession;
			end
		end
	else
		usedInString = "Unknown";
	end
	return usedInString;
end

function MTracker:getMaterialCounts(code, player, guildName, realmName)
	if not code then return 0,0,0,0; end --should not happen, but just incase
	if (not player) then player = MTracker_CurrentPlayer; end
	if (not guildName) then guildName = GetGuildInfo("player"); end
	if (not realmName) then realmName = MTracker_CurrentPlayer[2]; end

	local tableNbArg = self.db.account.materials[code].ByPlayer[realmName];
	local tableGNbArg = self.db.account.materials[code].ByGuild[realmName][guildName];

	local nbInBag, nbInBank, nbInReroll, nbInMail, nbInGBank = self:getMaterialCountsWithTable(tableNbArg, tableGNbArg, MTracker_CurrentPlayer[1]);
	return nbInBag, nbInBank, nbInReroll, nbInMail, nbInGBank;
end


function MTracker:getMaterialCountsWithTable(tableNbArg, tableGNbArg, playerName)
	if (not playerName) then playerName = MTracker_CurrentPlayer[1]; end
	
	local nbInBank = 0;
	local nbInReroll =0;
	local nbInBag =0;
	local nbInMail=0;
	local nbInGBank=0
	if (tableNbArg~=nil) then
		for name, bagTable in pairs (tableNbArg) do
			if (name == playerName) then
				nbInBag = bagTable["NbInBag"];
				nbInBank = bagTable["NbInBank"];
				nbInMail = bagTable["NbInMail"];
			else
				nbInReroll = (bagTable["NbInBank"] + bagTable["NbInBag"] + bagTable["NbInMail"] + nbInReroll);
			end
		end
	end
	if (tableGNbArg~=nil) then
		for tabName, tagTable in pairs (tableGNbArg) do
			nbInGBank=nbInGBank+tagTable["NbInGBank"];
		end
	end
	return nbInBag, nbInBank, nbInReroll, nbInMail, nbInGBank;
end

function MTracker:UseTooltips_Update()
	--need to hook tooltip
	if (MTracker_UseTooltips) then
		if (IsAddOnLoaded("EnhTooltip") and IsAddOnLoaded("Stubby")) then
			Stubby.UnregisterFunctionHook("EnhTooltip.AddTooltip", MTracker_HookTooltip)
		end
		MTracker_UseTooltips=false;
		self:Print("MaterialsTracker: Tooltips disabled");
	else
		if (IsAddOnLoaded("EnhTooltip") and IsAddOnLoaded("Stubby")) then
			Stubby.RegisterFunctionHook("EnhTooltip.AddTooltip", 500, MTracker_HookTooltip)
		end
		MTracker_UseTooltips=true;
		self:Print("MaterialsTracker: Tooltips enabled");
	end
end


function MTracker:ShowCountsInChat(itemlink)
	self:LevelDebug(mt_TRACE, "ShowCountsInChat enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if (itemlink) then
		local code = self:CodeFromLink(itemlink);
		if (code==nil) then return; end

		if (not self.db.account.materials[code].Name) then
			self:Print(itemlink.." is not being tracked");
			return;
		end

		self:Print(itemlink.." on the following players");
		local players = self.db.account.players[realmName];
		for playerName,v in pairs(players) do
			local nbInBag = self.db.account.materials[code].ByPlayer[realmName][playerName].NbInBag;
			local nbInBank = self.db.account.materials[code].ByPlayer[realmName][playerName].NbInBank;
			local nbInMail = self.db.account.materials[code].ByPlayer[realmName][playerName].NbInMail;
			self:Print(" "..playerName..": Bags="..nbInBag..", Bank="..nbInBank..", Mail="..nbInMail);
		end
		self:Print("");
		self:Print(itemlink.." in the following guilds");
		local tableGNbArg = self.db.account.materials[code].ByGuild[realmName];
		for guildName, guildTable in pairs (tableGNbArg) do
			local nbInGBank=0;
			for tabName, tagTable in pairs (guildTable) do
				nbInGBank=nbInGBank+tagTable["NbInGBank"];
			end
			self:Print( guildName..": "..nbInGBank);
		end
	end
end

function MTracker:AddItem(itemlink)
	self:LevelDebug(mt_TRACE, "AddItem enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if (itemlink) then
		local code = self:CodeFromLink(itemlink);
		if (not code) then return; end

--		local itemName, itemLink, itemRarity, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture = GetItemInfo("item:"..code);
		local itemName, itemLink, itemRarity, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, invTexture = GetItemInfo(itemlink);
		if (not itemName) then return nil; end

		self.db.account.materials[code].Texture = itemTexture;
		self.db.account.materials[code].Link = itemLink;
		self.db.account.materials[code].Name = itemName;
		self.db.account.materials[code].tracked = true;

		self:Print("Item "..itemlink.." added");

	end

end


-- this function will compare the current DB version, and the users DB version and see if it needs to be updated.
-- this will only be used when key data has changed, like the occurence in wow patch 2.0.1, when itemlinks were changed.
function MTracker:CheckDatabaseVersion()
	self:Print("CheckDatabaseVersion");
	local needsCleaning=false;

	if (self.db.account.config.DBVersion) then
		local existing = tonumber(self.db.account.config.DBVersion);
		local new = MATERIALSTRACKER_DB_VERSION;

		self:Print("existing is "..existing);
		self:Print("new is "..new);

		if (existing < new) then 
			needsCleaning=true;
		end
	else
		needsCleaning=true;
	end

	if (needsCleaning) then
--		MessageFrame:AddMessage("MaterialsTracker has detected that your database is outdated.  It will be reset now.", 0.8, 0.2, 0.2, 1.0, 5);
		self:Print("MaterialsTracker has detected that your database is outdated.  It will be reset now.");
		self.db.account.materials={};
		self.db.account.players={};
	end

	self.db.account.config.DBVersion=MATERIALSTRACKER_DB_VERSION;
	
end



--------------------common Util functions--------------------

--returns the name from the item link
--function MTracker:NameFromLink(link)
--	local name;
--	if( not link ) then
--		return nil;
--	end
--
--	--"|cffffffff|Hitem:3819:0:0:0|h[Wintersbite]|h|r"		--from 1.12
--	--"|cffffffff|Hitem:3819:0:0:0:0:0:0:0|h[Wintersbite]|h|r"	--from 2.00
--	return string.match(link, "|c%x+|Hitem:%d+:%d+:%d+:%d+:%d+:%d:%d:%d+|h%[(.-)%]|h|r");
--end

function MTracker:CodeFromLink(link)
	if (not link) then return nil; end
	if (type(link) ~= 'string') then return end
	
	local itemID = self:breakLink(link);
	return itemID;
end

function MTracker:GetNACFromLink(link)
	if (not link) then return end;
	if (type(link) ~= 'string') then return end;

	local itemID, _, _, _, name = self:breakLink(link);

	return itemID, name;
end

--copied from EnhTooltip, thanks guys
--Given an item link, splits it into it's component parts as follows:
function MTracker:breakLink(link)
	if (type(link) ~= 'string') then return end;
	local lType, itemID, enchant, gemSlot1, gemSlot2, gemSlot3, gemBonus, randomProp, uniqID, lichKing = MTracker:breakHyperlink("Hitem:", 6, strsplit("|", link))
	if (lType ~= "item") then return end
	name = link:match("|h%[(.-)%]|h")
	return tonumber(itemID) or 0, tonumber(randomProp) or 0, tonumber(enchant) or 0, tonumber(uniqID) or 0, tostring(name), tonumber(gemSlot1) or 0, tonumber(gemSlot2) or 0, tonumber(gemSlot3) or 0, tonumber(gemBonus) or 0, randomFactor, tonumber(lichKing) or 0
end

-- Given a Blizzard item link, breaks it into it's itemID, randomProperty, enchantProperty, uniqueness, name and the four gemSlots.
--This is a copy of the Auctioneer Adv version of breakitemlink, does the job very well compared to my code
function MTracker:breakHyperlink(match, matchlen, ...)
	local v
	local n = select("#", ...)
	for i = 2, n do
		v = select(i, ...)
		if (v:sub(1,matchlen) == match) then
			return strsplit(":", v:sub(2))
		end
	end
end

function isNullOrValue(value)
	if (value) then 
		return value;
	else 
		return "nil";
	end
end

function isNullOrFalse(value)
	if (value) then 
		return true;
	else 
		return false;
	end
end

function getTrueOrFalse(value)
	if (value) then 
		return "true";
	else 
		return "false";
	end
end

