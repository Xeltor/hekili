local fixture = require("Forever.helpers.paladin_protection")

describe("Protection Paladin personal spell bindings", function()
    it("checks the effective key, exact cast recipient and every other bound copy of the spell", function()
        local body = "#showtooltip\n/cast [@player] Holy Light"
        local command, kind, second = "MULTIACTIONBAR1BUTTON1", "macro", false
        local macroSlotID, duplicate, label = 7, false, "Heal me"
        local H = fixture.paladin(30, 500, {
            known = { 635, 639, 19750 },
            beforeLoad = function(world)
                local env = world.env
                local info = env.C_Spell.GetSpellInfo
                env.C_Spell.GetSpellInfo = function(id)
                    return info(id == "Holy Light" and 639 or id == "Flash of Light" and 19750 or id)
                end
                env.Constants = env.Constants or {}
                env.Constants.MacroConsts = { MAX_ACCOUNT_MACROS = 120 }
                env.GetMacroBody = function(id)
                    if id == 7 then
                        return body
                    end
                end
                env.GetMacroSpell = function()
                    return 639
                end
                env.GetNumMacros = function()
                    return 7, 1
                end
                env.C_ActionBar.GetActionText = function(slot)
                    return slot == 61 and label
                end
                env.C_Macro = {
                    GetMacroName = function(i)
                        if i == 7 or i == 121 and duplicate then
                            return "Heal me"
                        end
                        return "Macro " .. i
                    end,
                }
                env.GetBindingAction = function(key)
                    return key == "3" and command or "ACTIONBUTTON1"
                end
                env.GetBindingKey = function(key)
                    if key == "MULTIACTIONBAR1BUTTON1" then
                        return "3"
                    end
                    if second and key == "ACTIONBUTTON1" then
                        return "9"
                    end
                end
                env.GetActionInfo = function(slot)
                    if slot == 61 then
                        return kind, kind == "macro" and macroSlotID or 639
                    end
                    if second and slot == 1 then
                        return "spell", 635
                    end
                end
            end,
        })
        H.ctl.cvars.autoSelfCast = "0"
        H.ctl.friendly.target = true
        H.ns.ReadKeybindings()
        assert.is_true(H.Hekili:CanSelfCastHelpfulSpell(635))
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(19750))
        command = "OPENALLBAGS"
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "override on the key")
        command = "MULTIACTIONBAR1BUTTON1"
        for _, unsafe in ipairs({
            "/cast [@party1] Holy Light",
            "/cast [@player] Flash of Light",
            "/cast [@player] Holy Light; Flash of Light",
            "/target party1\n/cast [@player] Holy Light",
            "/cast [@player] Holy Light\n/cast [@mouseover] Holy Light",
        }) do
            body = unsafe
            assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "edited macro " .. unsafe)
        end
        body = "/cast [target=player] Holy Light"
        assert.is_true(H.Hekili:CanSelfCastHelpfulSpell(635))
        label = "Macro 3"
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "the reported ID belonged to another macro")
        label = "Heal me"
        macroSlotID = 639
        H.ns.ReadKeybindings()
        assert.is_true(H.Hekili:CanSelfCastHelpfulSpell(635), "Forever gave the spell ID and a unique macro label")
        duplicate = true
        H.Fire("UPDATE_MACROS")
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "same macro label on the character and account")
        macroSlotID, duplicate = 7, false
        H.Fire("UPDATE_MACROS")
        kind = "spell"
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "slot replaced before another key scan")
        kind, second = "macro", true
        H.ns.ReadKeybindings()
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "another bound copy can heal the selected ally")
        H.ctl.cvars.autoSelfCast, H.ctl.friendly.target = "1", false
        body, second = "/cast [@party1] Holy Light", false
        H.ns.ReadKeybindings()
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "another recipient overrides native auto self-cast")
        kind = "spell"
        H.ns.ReadKeybindings()
        assert.is_true(H.Hekili:CanSelfCastHelpfulSpell(635), "native button on an enemy")
        kind = "macro"
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "bar was edited after that scan")
        local opts = H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id]
        opts.abilities.holy_light.keybind = "CTRL+2"
        assert.is_false(H.Hekili:CanSelfCastHelpfulSpell(635), "unverified manual override")
    end)
end)
