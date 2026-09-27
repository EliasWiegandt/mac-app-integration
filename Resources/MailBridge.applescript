use framework "Foundation"

on encoded(valueToEncode)
    if valueToEncode is missing value then set valueToEncode to ""
    set valueText to valueToEncode as text
    set valueData to (current application's NSString's stringWithString:valueText)'s dataUsingEncoding:(current application's NSUTF8StringEncoding)
    return (valueData's base64EncodedStringWithOptions:0) as text
end encoded

on boxTree(parentBox)
    set resultBoxes to {parentBox}
    tell application "Mail" to set childBoxes to mailboxes of parentBox
    repeat with childBox in childBoxes
        set resultBoxes to resultBoxes & my boxTree(contents of childBox)
    end repeat
    return resultBoxes
end boxTree

on messageLine(oneMessage)
    tell application "Mail"
        set fields to {(id of oneMessage) as text, my encoded(subject of oneMessage), my encoded(sender of oneMessage), my encoded((date received of oneMessage) as text), my encoded(name of mailbox of oneMessage), (read status of oneMessage) as text}
    end tell
    set AppleScript's text item delimiters to tab
    set lineText to fields as text
    set AppleScript's text item delimiters to ""
    return lineText
end messageLine

on attachmentLine(oneAttachment)
    tell application "Mail"
        set attachmentMIME to ""
        try
            set attachmentMIME to MIME type of oneAttachment
        end try
        set fields to {my encoded(id of oneAttachment), my encoded(name of oneAttachment), my encoded(attachmentMIME), (file size of oneAttachment) as text, (downloaded of oneAttachment) as text}
    end tell
    set AppleScript's text item delimiters to tab
    set lineText to fields as text
    set AppleScript's text item delimiters to ""
    return lineText
end attachmentLine

on run argv
    if (count of argv) is not 4 and (count of argv) is not 6 then error "Invalid Mail bridge arguments"
    set operation to item 1 of argv
    set accountAddress to item 2 of argv
    set selectorValue to item 3 of argv
    set resultLimit to (item 4 of argv) as integer

    tell application "Mail"
        set selectedAccount to missing value
        repeat with oneAccount in accounts
            if (email addresses of oneAccount) contains accountAddress then
                set selectedAccount to contents of oneAccount
                exit repeat
            end if
        end repeat
        if selectedAccount is missing value then error "The configured iCloud address was not found in Apple Mail"
        set topBoxes to mailboxes of selectedAccount
    end tell

    set allBoxes to {}
    repeat with topBox in topBoxes
        set allBoxes to allBoxes & my boxTree(contents of topBox)
    end repeat

    if operation is "search" then
        set resultLines to {}
        repeat with oneBox in allBoxes
            tell application "Mail"
                set matchingMessages to (messages of oneBox whose subject contains selectorValue or sender contains selectorValue)
                repeat with oneMessage in matchingMessages
                    set end of resultLines to my messageLine(contents of oneMessage)
                    if (count of resultLines) is greater than or equal to resultLimit then exit repeat
                end repeat
            end tell
            if (count of resultLines) is greater than or equal to resultLimit then exit repeat
        end repeat
        set AppleScript's text item delimiters to linefeed
        set resultText to resultLines as text
        set AppleScript's text item delimiters to ""
        return resultText
    else if operation is "read" or operation is "attachments" or operation is "save_attachment" then
        set targetID to selectorValue as integer
        repeat with oneBox in allBoxes
            set oneMessage to missing value
            tell application "Mail"
                try
                    set oneMessage to first message of oneBox whose id is targetID
                end try
                if oneMessage is not missing value then
                    if operation is "read" then
                        set details to my messageLine(oneMessage)
                        set bodyText to my encoded(content of oneMessage)
                        return details & tab & bodyText
                    else if operation is "attachments" then
                        set resultLines to {}
                        repeat with oneAttachment in mail attachments of oneMessage
                            set end of resultLines to my attachmentLine(contents of oneAttachment)
                        end repeat
                        set AppleScript's text item delimiters to linefeed
                        set resultText to resultLines as text
                        set AppleScript's text item delimiters to ""
                        return resultText
                    else
                        if (count of argv) is not 6 then error "Missing attachment ID or destination"
                        set targetAttachmentID to item 5 of argv
                        set destinationPath to item 6 of argv
                        repeat with oneAttachment in mail attachments of oneMessage
                            if (id of oneAttachment) is targetAttachmentID then
                                save oneAttachment in (POSIX file destinationPath)
                                return my attachmentLine(contents of oneAttachment)
                            end if
                        end repeat
                        error "Attachment ID not found in the selected message"
                    end if
                end if
            end tell
        end repeat
        error "Message ID not found in the configured iCloud account"
    else
        error "Unknown Mail operation"
    end if
end run
