MATERIALSTRACKER_VERSION = "60000.01";
MATERIALSTRACKER_DB_VERSION = 40200;

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
local MTracker_LastTradeSkillOpenTime=0;
local MTracker_TradeSkillPauseTime=2;
local MTracker_TradeSkillIsOpen = false;
local MTracker_TradeSkillNeedScan = false;

local tooltip = LibStub("nTipHelper:1")

MTracker = LibStub("AceAddon-3.0"):NewAddon("MTracker", "AceConsole-3.0", "AceEvent-3.0", "AceHook-3.0")
local AceConfig = LibStub("AceConfig-3.0");


local MTracker = _G.MTracker

local debugf = tekDebug and tekDebug:GetFrame("MTracker");
local function Debug(...) 
	if debugf then 
		debugf:AddMessage(string.join(", ", ...)) 
	end 
end

local materialsDefault = {
	global = {
		materials = {
			['**'] = {
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
	}
}
local configDefault = {
	global = {
		config = {
			DBVersion=0,   
		},
	}
}

MTrackerOptionsTable = {
	type = "group",
	args = {
		resetdata = {
			type = "execute",
			name = "reset to the default config",
			desc = "reset",
			func = function() MTracker.db:ResetDB(); end,
		},
		tooltips = {
			type = "execute",
			name = "update the usage of tooltips",
			desc = "reset",
			func = function() MTracker:UseTooltips_Update(); end,
		},
		item = {
			type = "input",
			name = "item",
			desc = "list item counts",
			usage = "<itemlink>",
			get = false,
			set = function(info,v) MTracker:ShowCountsInChat(info,v); end,
		},
		additem = {
			type = "input",
			name = "additem",
			desc = "add an item to the database",
			usage = "<itemlink>",
			get = false,
			set = function(info,v) MTracker:AddItem(info,v); end,
		},
--		debugLevel = {
--			type = "input",
--			name = "debugLevel",
--			desc = "change debug level.  1=INFO, 2=TRACE",
--			usage = "<level>",
--			get = false,
--			set = function(info,v) MDebug:SetDebugLevel(tonumber(v)); end,
--		},
	}
}

function MTracker:OnInitialize()
	--Setup our chat command interface
	AceConfig:RegisterOptionsTable("MTracker", MTrackerOptionsTable, {"mtracker"})

	local acedb = LibStub:GetLibrary("AceDB-3.0")
	MTracker.db = acedb:New("MTrackerDB", materialsDefault, true);
	MTracker.dbconfig = acedb:New("MTrackerConfigDB", configDefault, true);
--	MTracker.db = acedb:New("MTrackerPerCharDB", materialsDefault, true);

	MTracker_CurrentPlayer = {UnitName("player"), GetRealmName()};
	MTracker:CheckDatabaseVersion();
end

function MTracker:OnEnable()
	-- Hook in new tooltip code
	tooltip:Activate();
	tooltip:AddCallback( { type = "item", callback = MTracker_HookTooltip }, 500)

	-- events
	MTracker:RegisterOurEvents();

	MTracker:AddUserToPlayerTable();
end

function MTracker:AddUserToPlayerTable()
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];
	
	--create the realm table if it does not yet exist.
	if (not MTracker.db.global.players[realmName]) then
		MTracker.db.global.players[realmName]={};
	end
	if (not MTracker.db.global.players[realmName][playerName]) then
		MTracker.db.global.players[realmName][playerName]=1;
	end
end

function MTracker:RegisterOurEvents()
	MTracker:RegisterEvent("BAG_UPDATE", "UpdateNumberInBag");
	MTracker:RegisterEvent("TRADE_SKILL_SHOW");
	MTracker:RegisterEvent("TRADE_SKILL_CLOSE");
	MTracker:RegisterEvent("BANKFRAME_OPENED", "BankIsOpened");
	MTracker:RegisterEvent("BANKFRAME_CLOSED", "BankIsClosed");
	MTracker:RegisterEvent("MAIL_SHOW", "MailboxIsOpened");
	MTracker:RegisterEvent("MAIL_CLOSED", "MailboxIsClosed");
	MTracker:RegisterEvent("MAIL_INBOX_UPDATE", "MailInboxUpdate");
	MTracker:RegisterEvent("GUILDBANKFRAME_OPENED", "GuildBankIsOpened");
	MTracker:RegisterEvent("GUILDBANKFRAME_CLOSED", "GuildBankIsClosed");
	MTracker:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", "UpdateNumberInGuildBank");
end

function MTracker:BankIsOpened()
	MTracker_BankIsOpen = true;
	MTracker:UpdateNumberInBank();
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
		MTracker:UpdateNumberInMailbox();
	end
end

function MTracker:GuildBankIsOpened()
	MTracker_GuildBankIsOpen = true;
--	MTracker:UpdateNumberInGuildBank();
end
function MTracker:GuildBankIsClosed()
	MTracker_GuildBankIsOpen = false;
end

function MTracker:TRADE_SKILL_SHOW()
	if (not MTracker:IsHooked(TradeSkillFrame, "OnUpdate")) then
		MTracker:HookScript(TradeSkillFrame, "OnUpdate", "TradeSkillFrameOnUpdate")
	end
	MTracker_TradeSkillIsOpen=true;
	MTracker_TradeSkillNeedScan=true;
	MTracker_LastTradeSkillOpenTime=GetTime();
end

function MTracker:TRADE_SKILL_CLOSE()
	MTracker:Unhook(TradeSkillFrame, "OnUpdate")
	MTracker_TradeSkillIsOpen=false;
	MTracker_TradeSkillNeedScan=false;
	MTracker_LastTradeSkillOpenTime=0;
end

function MTracker:TradeSkillFrameOnUpdate(...)
	if (not UnitAffectingCombat("player")) then
		if ((GetTime()-MTracker_LastTradeSkillOpenTime) > MTracker_TradeSkillPauseTime and MTracker_TradeSkillNeedScan) then
			MTracker:UpdateTradeSkillsSavedMaterials();
		end
	end
end

function MTracker:UpdateTradeSkillsSavedMaterials()
	Debug("UpdateTradeSkillsSavedMaterials enter");

	local tradeSkill = GetTradeSkillLine();
	--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateTradeSkillsSavedMaterials tradeSkill opened is "..isNullOrValue(tradeSkill));
	Debug("UpdateTradeSkillsSavedMaterials: tradeSkill opened is "..isNullOrValue(tradeSkill));

	--TODO: create table in localization file and check that tradeSkill is in there.
	if (tradeSkill~=nil) then
		MTracker_TradeSkillNeedScan=false;
		MTracker:UpdateTradeSkillSavedMaterials(tradeSkill);
	end
end

function MTracker:UpdateNumberInMailbox()
	--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInMailbox enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	-- if MTracker_MailUpdatesInProgress==true, don't process again, we are already doing it.
	-- hoping to fix hard locking issue i am experiencing.
	if (MTracker_MailboxIsOpen and not MTracker_MailUpdatesInProgress) then
		--set the lock, we only want to process the update once.
		MTracker_MailUpdatesInProgress=true;
		MTracker_LastMailScan=GetTime();	--GetTime is seconds that my computer has been running.

		MTracker:ResetMailboxCount();
				
		local nbr = GetInboxNumItems();
		for mailItem=1, nbr, 1 do
			for attachment=1, ATTACHMENTS_MAX_RECEIVE, 1 do
				local name, itemTexture, count, quality, canUse = GetInboxItem(mailItem, attachment);
				--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInMailbox itemName is "..isNullOrValue(name));

				if (name~= nil) then
					local code = MTracker:getCodeFromName(name);
--					if (code and MTracker.db.global.materials[code].tracked) then
					if (code and MTracker:ItemBeingTracked(code)) then
						--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInMailbox code is "..isNullOrValue(code));
						MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInMail = 
							(count + MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInMail);
					end
				end
			end
		end
		--unlock it when we are done.
		MTracker_MailUpdatesInProgress=false;
	end
end

function MTracker:UpdateNumberInBag()
	--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBag enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if (not UnitAffectingCombat("player")) then
		--reset bag count for this player
		MTracker:ResetBagCount();

		for bag=0, MTracker_NUMBER_OF_BAG_SLOTS, 1 do
			for slot=1, GetContainerNumSlots(bag), 1 do
				local itemLink = GetContainerItemLink(bag,slot);
				if(itemLink) then	--bag slot is empty.
	--				local itemName = MTracker:NameFromLink(itemLink);
	--				local code = MTracker:CodeFromLink(itemLink);	--the code is the key to the material

					local code, itemName = MTracker:GetNACFromLink(itemLink);
					--MDebug:LevelDebug(mt_TRACE, "MTracker_UpdateNumberInBag itemName is "..isNullOrValue(itemName));
					--MDebug:LevelDebug(mt_TRACE, "MTracker_UpdateNumberInBag code is "..isNullOrValue(code));

					if (code and MTracker:ItemBeingTracked(code)) then
						local texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag,slot);
						MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBag = 
							(itemCount + MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBag);
					end
				end
			end
		end	
		--call bank and mail update, incase the user is currently moving things between the bag and bank, or retrieving mail
		MTracker:UpdateNumberInBank();
		MTracker:UpdateNumberInMailbox();
	end
end

function MTracker:UpdateNumberInBank()
	--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if MTracker_BankIsOpen then
		--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank bank frame is open");
		MTracker:ResetBankCount();

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
					--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank slot,container is "..slot..","..container);
					local itemLink = GetContainerItemLink(container,slot)
					--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank itemLink is "..isNullOrValue(itemLink));
					if(itemLink) then	-- slot is empty.
--						local itemName = MTracker:NameFromLink(itemLink);
--						local code = MTracker:CodeFromLink(itemLink);	--this is the key to the material

						local code, itemName = MTracker:GetNACFromLink(itemLink);

						if (code and MTracker:ItemBeingTracked(code)) then
							local texture, itemCount, locked, quality, readable = GetContainerItemInfo(container,slot);
							MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBank = 
								(itemCount + MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBank);
						end
					end
				end
			end
		end
		if (IsReagentBankUnlocked()) then
		    for slot=1, GetContainerNumSlots(REAGENTBANK_CONTAINER), 1 do
			local itemLink = GetContainerItemLink(REAGENTBANK_CONTAINER,slot)
			--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInBank itemLink is "..isNullOrValue(itemLink));
			if(itemLink) then	-- slot is empty.
			    local code, itemName = MTracker:GetNACFromLink(itemLink);

			    if (code and MTracker:ItemBeingTracked(code)) then
			        local texture, itemCount, locked, quality, readable = GetContainerItemInfo(REAGENTBANK_CONTAINER,slot);
			        MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBank =
			            (itemCount + MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBank);
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
	--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateNumberInGuildBank enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];
	local guildName = GetGuildInfo("player");

	if (guildName~=nil) then
		if (MTracker_GuildBankIsOpen and GuildBankFrame.mode == "bank") then
			local tab = GetCurrentGuildBankTab();
			local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(tab);
			MTracker:ResetGBankCount(realmName, guildName,tab);
			for i=1, MAX_GUILDBANK_SLOTS_PER_TAB do				--currently 98
				index = mod(i, NUM_SLOTS_PER_GUILDBANK_GROUP);		--currently 14
				if ( index == 0 ) then
					index = NUM_SLOTS_PER_GUILDBANK_GROUP;
				end
				local texture, itemCount, locked = GetGuildBankItemInfo(tab, i);
				local itemLink = GetGuildBankItemLink(tab, i);
				local code, itemName = MTracker:GetNACFromLink(itemLink);
				if (code and tab and MTracker:ItemBeingTracked(code)) then
					MTracker.db.global.materials[code].ByGuild[realmName][guildName][tab].NbInGBank = 
						(itemCount + MTracker.db.global.materials[code].ByGuild[realmName][guildName][tab].NbInGBank);
				end
			end
		end
	end
end

function MTracker:ResetBagCount() 
	--MDebug:LevelDebug(mt_TRACE, "MTracker:ResetBagCount enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for k,v in pairs(MTracker.db.global.materials) do
		--MDebug:LevelDebug(mt_TRACE, "key is "..k);
		MTracker.db.global.materials[k].ByPlayer[realmName][playerName].NbInBag=0;
	end
end

function MTracker:ResetBankCount() 
	--MDebug:LevelDebug(mt_TRACE, "MTracker:ResetBankCount enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for k,v in pairs(MTracker.db.global.materials) do
		--MDebug:LevelDebug(mt_TRACE, "key is "..k);
		MTracker.db.global.materials[k].ByPlayer[realmName][playerName].NbInBank=0;
	end
end
function MTracker:ResetMailboxCount() 
	--MDebug:LevelDebug(mt_TRACE, "MTracker:ResetMailboxCount enter");
	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for k,v in pairs(MTracker.db.global.materials) do
		--MDebug:LevelDebug(mt_TRACE, "key is "..k);
		MTracker.db.global.materials[k].ByPlayer[realmName][playerName].NbInMail=0;
	end
end
function MTracker:ResetGBankCount(realmName, guildName,tab)
	--MDebug:LevelDebug(mt_TRACE, "MTracker:ResetGBankCount enter");
--	local playerName = MTracker_CurrentPlayer[1];
--	local realmName = MTracker_CurrentPlayer[2];
--	local guildName = GetGuildInfo("player");

	--create db table if nil
--	MTracker.db.global.materials[code].ByGuild={};
--	MTracker.db.global.materials[code].ByGuild[realmName]={};


	for k,v in pairs(MTracker.db.global.materials) do
		--MDebug:LevelDebug(mt_TRACE, "key is "..k);
		if (not MTracker.db.global.materials[k].ByGuild[realmName][guildName]) then
			MTracker.db.global.materials[k].ByGuild[realmName][guildName]={};
		end
		if (not MTracker.db.global.materials[k].ByGuild[realmName][guildName][tab]) then
			MTracker.db.global.materials[k].ByGuild[realmName][guildName][tab]={};
		end
		MTracker.db.global.materials[k].ByGuild[realmName][guildName][tab].NbInGBank=0;
	end
end
function MTracker:getLinkFromName(name)
	if (name==nil) then return end;

	for key,value in pairs(MTracker.db.global.materials) do 
		if (MTracker.db.global.materials[key].Name == name) then
			return MTracker.db.global.materials[key].Link;
		end
	end
	return nil;
end
function MTracker:getCodeFromName(name)
	if (name==nil) then return end;

	for key,value in pairs(MTracker.db.global.materials) do 
		if (MTracker.db.global.materials[key].Name == name) then
			return key;
		end
	end
	return nil;
end

function MTracker:AddProfessionNameToMaterial(itemCode, professionName) 
	--MDebug:LevelDebug(mt_TRACE, "MTracker:AddProfessionNameToMaterial enter");
	--MDebug:LevelDebug(mt_TRACE, "adding "..isNullOrValue(professionName).." to "..isNullOrValue(itemCode));

	if (not MTracker.db.global.materials[itemCode].UsedIn) then
		MTracker.db.global.materials[itemCode].UsedIn={};
	end
	MTracker.db.global.materials[itemCode].UsedIn[professionName]=true;
end


function MTracker:UpdateTradeSkillSavedMaterials(tradeSkillName)
	--MDebug:LevelDebug(mt_TRACE, "MTracker:UpdateTradeSkillSavedMaterials enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	for i=1, GetNumTradeSkills(), 1 do
		--skillType is either "header", if the skillIndex references to a heading, or a string indicating the difficulty to craft the item ("trivial", "easy" (?), "optimal", "difficult").
		local skillName, skillType, numAvailable, isExpanded = GetTradeSkillInfo(i)
		--MDebug:LevelDebug(mt_TRACE, "skillName is "..isNullOrValue(skillName));
		
		if (skillType ~="header") then
			for j=1, GetTradeSkillNumReagents(i), 1 do
				local reagentName, reagentTexture, reagentCount, playerReagentCount = GetTradeSkillReagentInfo(i, j);
				--MDebug:LevelDebug(mt_TRACE, "reagentName is "..isNullOrValue(reagentName));
				local reagentlink = GetTradeSkillReagentItemLink(i,j);
				local code = MTracker:CodeFromLink(reagentlink);
				--MDebug:LevelDebug(mt_TRACE, "code is "..isNullOrValue(code));

				if (code) then
					if (not MTracker.db.global.materials[code]) then
						MTracker.db.global.materials[code]={};
						MTracker.db.global.materials[code].ByPlayer={};
						MTracker.db.global.materials[code].ByPlayer[realmName]={};
						MTracker.db.global.materials[code].ByPlayer[realmName][playerName]={};
						MTracker.db.global.materials[code].ByGuild={};
						MTracker.db.global.materials[code].ByGuild[realmName]={};
					end
					MTracker.db.global.materials[code].Texture = reagentTexture;
					MTracker.db.global.materials[code].Link = reagentlink;
					MTracker.db.global.materials[code].Name = reagentName;
					MTracker.db.global.materials[code].tracked = true;
					MTracker:AddProfessionNameToMaterial(code, tradeSkillName);
				end
			end
		end		
	end
end

function MTracker:ItemBeingTracked(code) 
	if (not MTracker.db.global.materials[code]) then 
		return false; 
	end
	return MTracker.db.global.materials[code].tracked;
end

function MTracker:getUsedIn(code) 
	return MTracker.db.global.materials[code].UsedIn;
end

function MTracker_HookTooltip(tipFrame, item, count, name, link, quality)
	if (MTracker_UseTooltips) then
		tooltip:SetFrame(tipFrame)

		local code, iName = MTracker:GetNACFromLink(link);
		if (code and MTracker:ItemBeingTracked(code)) then	--checks if the code is valid, and also if the code is found in the mtracker database.
			local nbInBag, nbInBank, nbInReroll, nbInMail, nbInGuild = MTracker:getMaterialCounts(code);
--			local price = MTracker_getMaterialDefaultPrice(code);

			tooltip:AddLine(" ", nil, false);
			tooltip:SetColor(0,1,1);
			tooltip:AddLine("MaterialTracker Info"..":", nil, false);
			tooltip:SetColor(1,0.3,1);
			tooltip:AddLine("In Bags"..": "..nbInBag, nil, false);
			tooltip:AddLine("In Bank"..": "..nbInBank, nil, false);
			tooltip:AddLine("In Mail"..": "..nbInMail, nil, false);
			tooltip:AddLine("On Toons"..": "..nbInReroll, nil, false);
			tooltip:AddLine("In Guild"..": "..nbInGuild, nil, false);

			--add used-in information
			tooltip:AddLine("Used By"..": "..MTracker:BuildUsedInString(MTracker:getUsedIn(code)), nil, false);
			tooltip:AddLine(" ", nil, false);

--			EnhTooltip.AddLine("Cost"..": "..ESell_Money_getStringFormatWithColor(priceUnite), nil, false);
--			EnhTooltip.LineColor(1,0.3,1);
		end
	end

end

function MTracker_HookTooltip_old(funcVars, retVal, frame, name, link, quality, count)
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
	--MDebug:LevelDebug(mt_TRACE, "MTracker:BuildUsedInString enter");
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

	local tableNbArg = MTracker.db.global.materials[code].ByPlayer[realmName];
	local tableGNbArg = MTracker.db.global.materials[code].ByGuild[realmName][guildName];

	local nbInBag, nbInBank, nbInReroll, nbInMail, nbInGBank = MTracker:getMaterialCountsWithTable(tableNbArg, tableGNbArg, MTracker_CurrentPlayer[1]);
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
	return nbInBag or 0, nbInBank or 0, nbInReroll or 0, nbInMail or 0, nbInGBank or 0;
end

function MTracker:UseTooltips_Update()
	--need to hook tooltip
	if (MTracker_UseTooltips) then
		tooltip:RemoveCallback(MTracker_HookTooltip);
		MTracker_UseTooltips=false;
		MTracker:Print("MaterialsTracker: Tooltips disabled");
	else
		tooltip:AddCallback( { type = "item", callback = MTracker_HookTooltip }, 500)
		MTracker_UseTooltips=true;
		MTracker:Print("MaterialsTracker: Tooltips enabled");
	end
end


function MTracker:ShowCountsInChat(info, itemlink)
	--MDebug:LevelDebug(mt_TRACE, "ShowCountsInChat enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if (itemlink) then
		local code = MTracker:CodeFromLink(itemlink);
		if (code==nil) then return; end

		if (not MTracker.db.global.materials[code].Name) then
			MTracker:Print(itemlink.." is not being tracked");
			return;
		end

		MTracker:Print(itemlink.." on the following players");
		local players = MTracker.db.global.players[realmName];
		for playerName,v in pairs(players) do
			local nbInBag = MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBag or 0;
			local nbInBank = MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInBank or 0;
			local nbInMail = MTracker.db.global.materials[code].ByPlayer[realmName][playerName].NbInMail or 0;
			MTracker:Print(" "..playerName..": Bags="..nbInBag..", Bank="..nbInBank..", Mail="..nbInMail);
		end
		MTracker:Print("");
		MTracker:Print(itemlink.." in the following guilds");
		local tableGNbArg = MTracker.db.global.materials[code].ByGuild[realmName];
		for guildName, guildTable in pairs (tableGNbArg) do
			local nbInGBank=0;
			for tabName, tagTable in pairs (guildTable) do
				nbInGBank=nbInGBank+tagTable["NbInGBank"];
			end
			MTracker:Print( guildName..": "..nbInGBank);
		end
	end
end

function MTracker:AddItem(info, itemlink)
	--MDebug:LevelDebug(mt_TRACE, "AddItem enter");

	local playerName = MTracker_CurrentPlayer[1];
	local realmName = MTracker_CurrentPlayer[2];

	if (itemlink) then
		MTracker:Print("itemlink "..itemlink);
		local code = MTracker:CodeFromLink(itemlink);
		if (not code) then return; end

--		local itemName, itemLink, itemRarity, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture = GetItemInfo("item:"..code);
		local itemName, itemLink, itemRarity, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, invTexture = GetItemInfo(itemlink);
		if (not itemName) then return nil; end

		if (not MTracker.db.global.materials[code]) then
			MTracker.db.global.materials[code]={};
			MTracker.db.global.materials[code].ByPlayer={};
			MTracker.db.global.materials[code].ByPlayer[realmName]={};
			MTracker.db.global.materials[code].ByPlayer[realmName][playerName]={};
			MTracker.db.global.materials[code].ByGuild={};
			MTracker.db.global.materials[code].ByGuild[realmName]={};
		end
		MTracker.db.global.materials[code].Texture = itemTexture;
		MTracker.db.global.materials[code].Link = itemLink;
		MTracker.db.global.materials[code].Name = itemName;
		MTracker.db.global.materials[code].tracked = true;

		MTracker:Print("Item "..itemlink.." added");
	end

end


-- this function will compare the current DB version, and the users DB version and see if it needs to be updated.
-- this will only be used when key data has changed, like the occurence in wow patch 2.0.1, when itemlinks were changed.
function MTracker:CheckDatabaseVersion()
--	MTracker:Print("CheckDatabaseVersion");
	local needsCleaning=false;

	if (MTracker.dbconfig.global.config.DBVersion) then
		local existing = tonumber(MTracker.dbconfig.global.config.DBVersion);
		local new = MATERIALSTRACKER_DB_VERSION;

--		MTracker:Print("existing is "..existing);
--		MTracker:Print("new is "..new);

		if (existing < new) then 
			needsCleaning=true;
		end
	else
		needsCleaning=true;
	end

	if (needsCleaning) then
--		MessageFrame:AddMessage("MaterialsTracker has detected that your database is outdated.  It will be reset now.", 0.8, 0.2, 0.2, 1.0, 5);
		MTracker:Print("MaterialsTracker has detected that your database is outdated.  It will be reset now.");
		MTracker.db:ResetDB("Default");
--		MTracker.db.global.materials={};
--		MTracker.db.global.players={};
	end

--	MTracker:Print("database version is "..MTracker.dbconfig.global.config.DBVersion);
	MTracker.dbconfig.global.config.DBVersion=MATERIALSTRACKER_DB_VERSION;
--	MTracker:Print("database version is "..MTracker.dbconfig.global.config.DBVersion);
	
end



--------------------common Util functions--------------------

function MTracker:CodeFromLink(link)
	if (not link) then return nil; end
	if (type(link) ~= 'string') then return end
	
	local itemID = MTracker:breakLink(link);
	return itemID;
end

function MTracker:GetNACFromLink(link)
	if (not link) then return end;
	if (type(link) ~= 'string') then return end;

	local itemID, _, _, _, name = MTracker:breakLink(link);

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

