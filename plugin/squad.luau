--!nonstrict
local face = require("./face.luau")
local gridLayout=require("./layout.luau")
local model = require("./model.luau")
local animationClock = require("./animation_clock.luau")
local chat = require("./chat.luau")
local readState=require("./read_state.luau")
local chatTransition=require("./chat_transition.luau")
local chatProgress,chatFrom,chatTarget,chatStarted=0,0,0,0
local chatMode=false
local selectedId=nil
local drafts={}
local sendBusy={}
local chatNotice=""
local composeRevision=0
local bubbleNodes={}
local bubbleIdentity=nil
local chatAt=0
local messages={}
local transcriptError=""
local opened, closing, started, closeAt, last = false, false, 0, 0, 0
local hover = ""
local pinMode=false
local pins=require("./pins.luau")
local clocks = {}
local renders = 0
local healthAt = 0
local transitioning = false
local portraitCache = {}
local cachedSnapshot = nil
local snapshotAt = 0
local measuredAt, measuredFrames = 0, 0
function dismissBlank() panel.close() end
local function renderShell(height,children)
    local unused=math.max(0,890-height)
    panel.render(ui.column({key="panel-host",height=890,gap=0},{
        ui.column({key="shell",height=height,padding=12,gap=8,radius=18,fill=noctalia.getColor("surface") or "#202024"},children),
        ui.box({key="outside-chat",height=unused,visible=unused>0,fill="surface/0",onClick="dismissBlank"}),
    }))
end
local function animateChat(target)
    local now=noctalia.nowMs()
    chatProgress=chatTransition.progress(now,chatFrom,chatTarget,chatStarted)
    chatFrom=chatProgress chatTarget=target chatStarted=now
end
local function choose(id)
    local nextId=chatTransition.toggle(selectedId,id)
    if nextId==nil then
        chatMode=false animateChat(0)
    else
        selectedId=nextId chatMode=true animateChat(1)
        chatAt=0 chatNotice=""
    end
    update()
end
function collapse() closing=true closeAt=noctalia.nowMs() end
function update()
    if not opened then return end
    local now = noctalia.nowMs()
    chatProgress=chatTransition.progress(now,chatFrom,chatTarget,chatStarted)
    if chatTarget==0 and chatProgress<=0 then selectedId=nil end
    if closing and now-closeAt > 370 then panel.close() return end
    if not cachedSnapshot or now-snapshotAt>=250 then
        cachedSnapshot=noctalia.state.get("snapshot")
        snapshotAt=now
    end
    local s = cachedSnapshot
    if type(s)~="table" then return end
    local selectedAgent=nil
    for _,a in ipairs(s.agents) do if a.id==selectedId then selectedAgent=a end end
    if chatMode and not selectedAgent then selectedId=nil chatMode=false end
    if selectedId and now-chatAt>=1000 then messages,transcriptError=chat.messages(selectedId,now) chatAt=now end
    -- A list preview or a closing/partially revealed chat is not a read.
    if chatMode and not closing and chatProgress>=1 and transcriptError=="" then
        readState.mark(selectedAgent,messages)
    end
    transitioning = closing or now-started < 500
    local members = {}
    local page = math.max(0,tonumber(noctalia.state.get("squad_page")) or 0)
    local pages = math.max(1,math.ceil(#s.agents/gridLayout.pageLimit))
    if page>=pages then page=0 end
    local visibleCount=math.min(gridLayout.pageLimit,math.max(0,#s.agents-page*gridLayout.pageLimit))
    for index=page*gridLayout.pageLimit+1,math.min(#s.agents,page*gridLayout.pageLimit+gridLayout.pageLimit) do
        local a=s.agents[index]
        local slot=index-page*gridLayout.pageLimit
        local progress=math.clamp((now-started-(math.floor((slot-1)/8)*40+((slot-1)%8)*20))/200,0,1)
        if closing then progress=1-math.clamp((now-closeAt-(visibleCount-slot)*6)/170,0,1) end
        progress=progress*progress*(3-2*progress)
        -- Each member resumes as soon as its own reveal starts, independently
        -- of the remaining staggered entrances. Closing still freezes the pose.
        local memberPaused=closing or progress<=0
        local state=s.running and a.state or "asleep"
        if not clocks[a.id] or clocks[a.id].mood~=state then
            local seed=0
            for n=1,#a.id do seed=(seed*31+string.byte(a.id,n))%36000 end
            clocks[a.id]={mood=state,phase=seed,last=now,paused=memberPaused}
        end
        local clock=clocks[a.id]
        local phase=animationClock.step(clock,now,memberPaused)
        local id=a.id
        local color=a.waiting and "error" or "primary"
        local portrait=portraitCache[id]
        -- Keep texture and geometry stable during transitions. Only opacity
        -- changes at display cadence; character frames run separately at 30fps.
        if not portrait or (not memberPaused and now-portrait.at>=30) then
            portrait={path=face.path(state,phase,a.avatarShape,a.avatarColor),at=now}
            portraitCache[id]=portrait
        end
        table.insert(members,ui.column({key=id,width=60,height=82,align="center",justify="center",gap=4,
            opacity=progress,radius=12,fill=(hover==id or selectedId==id) and "primary/0.15" or (a.waiting and "error/0.10" or "surface/0"),
            onClick=function() if pinMode then pins.toggle(id) else choose(id) end end,
            onHover=function(value) if value=="true" then hover=id elseif hover==id then hover="" end end,
            tooltip=a.name.." · "..(model.labels[state] or "待命")..(a.waiting and ("\n"..a.reason) or "")}, {
            ui.image({key="face-"..id,path=portrait.path,width=44,height=44}),
            ui.label({text=(pinMode and (pins.get()[id] and "✓ " or "○ ") or "")..model.clean(a.name,7),fontSize=10,maxLines=1,color=hover==id and "primary" or "on_surface"}),
            ui.label({text=a.waiting and "等你处理" or (a.unread>0 and tostring(a.unread).." 未读" or ""),fontSize=9,color=color}),
        }))
    end
    if #members==0 then table.insert(members,ui.label({text="还没有 BOT，先打开 Grok Bot 开始聊天",fontSize=12})) end
    local memberRows={}
    for start=1,#members,gridLayout.columns do
        local row={}
        for i=start,math.min(#members,start+gridLayout.columns-1) do table.insert(row,members[i]) end
        table.insert(memberRows,ui.row({key="member-row-"..tostring(start),gap=6,align="center",justify="center",height=84},row))
    end
    local rowCount=gridLayout.rows(visibleCount)
    local gridHeight=rowCount*84+(rowCount-1)*6
    local compactHeight=154+(rowCount-1)*90
    local grid=ui.column({key="members",gap=6,height=gridHeight},memberRows)
    local footer={ui.label({text=hover~="" and "点击成员查看消息" or model.summary(s),fontSize=10,color="on_surface_variant",flexGrow=1}),
        ui.button({glyph="chevron-up",variant="ghost",onClick="collapse",tooltip="收起小队"})}
    table.insert(footer,ui.button({text=pinMode and "完成设置" or "常驻设置",variant="ghost",onClick=function()
        pinMode=not pinMode
        if pinMode then chatMode=false animateChat(0) end
        update()
    end}))
    if pinMode then footer[1]=ui.label({text="点击头像切换常驻 · 最多显示 10 位",fontSize=10,color="primary",flexGrow=1}) end
    if pages>1 then table.insert(footer,ui.button({text=tostring(page+1).."/"..tostring(pages),variant="ghost",onClick=function() noctalia.state.set("squad_page",(page+1)%pages) started=now end})) end
    if chatProgress<=0 and not chatMode then
        renderShell(compactHeight,{
            grid,
            ui.row({key="footer",gap=8,align="center"},footer),
        })
        return
    end
    table.insert(footer,ui.button({text="收起聊天",glyph="chevron-up",variant="ghost",onClick=function()
        chatMode=false animateChat(0) update()
    end}))
    local identity=tostring(selectedId)..":"..tostring(messages)..":"..transcriptError
    if identity~=bubbleIdentity then
    local bubbles={}
    for _,message in ipairs(messages) do
        table.insert(bubbles,ui.column({key="message-"..message.id,padding=12,gap=5,radius=12,fill=message.role=="你" and "primary/0.12" or "surface_container"},{
            ui.label({text=message.role=="你" and "你" or (selectedAgent and selectedAgent.name or "BOT"),fontSize=10,color="on_surface_variant"}),
            ui.markdown({text=message.text}),
        }))
    end
    if #bubbles==0 then table.insert(bubbles,ui.label({text=transcriptError~="" and transcriptError or "还没有消息",fontSize=13,color="on_surface_variant"})) end
    bubbleNodes=bubbles bubbleIdentity=identity
    end
    local bubbles=bubbleNodes
    local title=selectedAgent and selectedAgent.name or "BOT 小队"
    local currentId=selectedId
    local draft=currentId and drafts[currentId] or ""
    local function submitCurrent(value)
        if not currentId or sendBusy[currentId] then return end
        if not s.bridgeConnected then chatNotice="桥接未连接，草稿已保留" update() return end
        if type(value)=="string" then drafts[currentId]=value noctalia.state.set("drafts",drafts) end
                if sendBusy[currentId] then return end
                local submitted=drafts[currentId] or ""
                sendBusy[currentId]=true
                local ok,notice=chat.send(currentId,submitted,function(reply)
                    sendBusy[currentId]=nil
                    if reply.ok then
                        if drafts[currentId]==submitted then drafts[currentId]="" noctalia.state.set("drafts",drafts) end
                        if selectedId==currentId then composeRevision=composeRevision+1 chatNotice="已提交应用发送队列，等待回复" end
                    elseif selectedId==currentId then chatNotice=reply.error or "发送失败，草稿已保留" end
                    chatAt=0 update()
                end)
                if not ok then sendBusy[currentId]=nil end
                chatNotice=notice update()
    end
    local children={
        grid,
        ui.row({key="footer",gap=8,align="center"},footer),
        ui.separator(),
        ui.row({gap=8,align="center"},{ui.label({text=title,fontSize=16,fontWeight="bold",flexGrow=1}),ui.label({text=selectedAgent and model.labels[selectedAgent.state] or "",fontSize=11,color="on_surface_variant"})}),
        ui.scroll({key="chat-"..tostring(currentId),flexGrow=1,gap=10,stickToBottom=true},bubbles),
        ui.input({key="compose-"..tostring(currentId).."-"..tostring(composeRevision),height=72,multiline=true,submitOnEnter=true,onSubmit=function(value) submitCurrent(value) end,value=draft or "",placeholder="给 "..title.." 写消息…（Enter 发送，Shift+Enter 换行）",onChange=function(value) if currentId then drafts[currentId]=value noctalia.state.set("drafts",drafts) end end}),
        ui.row({gap=8,align="center"},{ui.label({text=chatNotice~="" and chatNotice or (s.bridgeConnected and "本机桥接已连接 · 消息交由应用发送" or "桥接未连接，草稿会保留"),fontSize=10,color="on_surface_variant",flexGrow=1,maxLines=2}),
            ui.button({text=sendBusy[currentId] and "提交中…" or "发送",glyph="send",variant="primary",enabled=currentId~=nil and s.bridgeConnected==true and not sendBusy[currentId],onClick=function() submitCurrent() end})}),
    }
    local chatChildren={}
    for i=3,#children do table.insert(chatChildren,children[i]) end
    local layout={children[1],children[2],ui.scroll({key="chat-reveal",height=math.max(1,466*chatProgress),opacity=chatProgress},{
        ui.column({key="chat-content",height=450,gap=8},chatChildren),
    })}
    renderShell(compactHeight+466*chatProgress,layout)
    renders=renders+1
    if not transitioning and now-healthAt>2000 then
        noctalia.writeFile(noctalia.pluginDataDir().."/squad-health.json",noctalia.json.encode({ok=true,frames=renders,members=#members,updated=now,renderFps=math.floor((renders-measuredFrames)*1000/math.max(1,now-measuredAt))}))
        healthAt=now
        measuredAt=now measuredFrames=renders
    end
end
function onOpen(context)
    drafts=noctalia.state.get("drafts") or drafts
    selectedId=nil chatMode=false pinMode=false
    chatProgress=0 chatFrom=0 chatTarget=0 chatStarted=noctalia.nowMs()
    measuredAt=noctalia.nowMs() measuredFrames=renders cachedSnapshot=nil opened=true closing=false started=noctalia.nowMs()-((chatMode or context=="return") and 1000 or 0) hover="" panel.setNeedsFrameTick(true) update() end
function onClose() opened=false closing=false
    for _,clock in pairs(clocks) do clock.paused=true end
    panel.setNeedsFrameTick(false)
end
function onFrameTick()
    local now=noctalia.nowMs()
    local interval = (closing or now-started<500 or now-chatStarted<270) and 15 or 30
    if now-last>=interval then last=now update() end
end
function onIpc(event)
    if event=="toggle" then
        if opened then collapse() else noctalia.togglePanel("local/grok-bot:squad") end
    elseif event=="health" then update() end
end
panel.setNeedsFrameTick(true)
