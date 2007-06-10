module Ghf.Editor where

import Graphics.UI.Gtk hiding (afterToggleOverwrite)
import Graphics.UI.Gtk.SourceView
import Graphics.UI.Gtk.Multiline.TextView
import Control.Monad.Reader
import Data.IORef
import System.FilePath
import System.Directory
import System.Console.GetOpt
import System.Environment
import Data.Maybe ( fromMaybe, isJust, fromJust )
import Text.Printf
  
import Ghf.Core

newTextBuffer :: String -> Maybe FileName -> GhfAction
newTextBuffer bn mbfn = do
    -- create the appropriate language
    nb <- readGhf notebook1
    bufs <- readGhf buffers
    stats<- readGhf statusbars
    let (ind,rbn) = figureOutBufferName bufs bn 0
    buf <- lift $ do
        lm      <-  sourceLanguagesManagerNew
        langM   <-  sourceLanguagesManagerGetLanguageFromMimeType lm "text/x-haskell"
        lang    <-  case langM of
                        (Just lang) -> return lang
                        Nothing -> do
                            langDirs <- sourceLanguagesManagerGetLangFilesDirs lm
                            error ("please copy haskell.lang to one of the following" 
                                   ++ "directories:\n"
                                ++ unlines langDirs)

        -- create a new SourceBuffer object
        buffer <- sourceBufferNewWithLanguage lang
 
        -- load up and display a file
        fileContents <- case mbfn of
            Just fn -> readFile fn
            Nothing -> return "\n\n\n\n\n"
        sourceBufferBeginNotUndoableAction buffer
        textBufferSetText buffer fileContents
        textBufferSetModified buffer False
        sourceBufferEndNotUndoableAction buffer
        siter <- textBufferGetStartIter buffer
        textBufferPlaceCursor buffer siter
        sourceBufferSetHighlight buffer True

        -- create a new SourceView Widget
        sv <- sourceViewNewWithBuffer buffer
        f <- fontDescriptionNew
        fontDescriptionSetFamily f "Monospace"
        widgetModifyFont sv (Just f)
        sourceViewSetShowLineNumbers sv True
        sourceViewSetMargin sv 90
        sourceViewSetShowMargin sv True
        sourceViewSetInsertSpacesInsteadOfTabs sv True
        sourceViewSetTabsWidth sv 4
        sourceViewSetSmartHomeEnd sv True

        -- put it in a scrolled window
        sw <- scrolledWindowNew Nothing Nothing
        sw `containerAdd` sv
        scrolledWindowSetPolicy sw PolicyAutomatic PolicyAutomatic
        sw `scrolledWindowSetShadowType` ShadowIn
        notebookPrependPage nb sw rbn
        mbPn <- notebookPageNum nb sw
        widgetShowAll nb
        case mbPn of
            Just i -> notebookSetCurrentPage nb i
            Nothing -> putStrLn "Notebook page not found"

        -- statusbars  
        statusbarPush (stats !! 0) 1 ""
        writeCursorPositionInStatusbar buffer (stats !! 0)

        afterMoveCursor sv (\_ _ _ -> writeCursorPositionInStatusbar buffer (stats !! 0))
        afterEndUserAction buffer (writeCursorPositionInStatusbar buffer (stats !! 0))
        afterSwitchPage nb (\pn1 -> do  pn2 <- notebookPageNum nb sw;
                                        if isJust pn2 && pn1 == fromJust pn2 
                                            then writeCursorPositionInStatusbar buffer (stats !! 0)
                                            else return ())
        widgetAddEvents sv [ButtonReleaseMask]
        onButtonRelease sv (\ _ -> do writeCursorPositionInStatusbar buffer (stats !! 0); return False)
        afterModifiedChanged buffer (markLabelAsChanged buffer nb sw)        

        statusbarPush (stats !! 1) 1 "INS"
        afterToggleOverwrite sv (writeOverwriteInStatusbar sv nb sw (stats !! 1))
        afterSwitchPage nb (\ _ -> writeOverwriteInStatusbar sv nb sw (stats !! 1))
        return (GhfBuffer mbfn bn ind sv sw)
    modifyGhf_ (\ghf -> return (ghf{buffers = buf : bufs}))

writeCursorPositionInStatusbar :: SourceBuffer -> Statusbar -> IO()
writeCursorPositionInStatusbar buf stat = do
    modi <- textBufferGetModified buf
    mark <- textBufferGetInsert buf
    iter <- textBufferGetIterAtMark buf mark
    line <- textIterGetLine iter
    col  <- textIterGetLineOffset iter
    statusbarPop stat 1
    statusbarPush stat 1 $printf "Ln %4d, Col %3d" (line + 1) (col + 1)
    return ()

writeOverwriteInStatusbar :: SourceView -> Notebook -> ScrolledWindow -> Statusbar -> IO()
writeOverwriteInStatusbar sv nb sw stat = do
    i <- notebookGetCurrentPage nb
    i2 <- notebookPageNum nb sw
    if isJust i2 && i == fromJust i2
        then do
            modi <- textViewGetOverwrite sv
            statusbarPop stat 1
            statusbarPush stat 1 $if modi then "OVR" else "INS"
            return () 
        else return ()

markLabelAsChanged buf nb sw = do
    modified <- textBufferGetModified buf
    (Just text) <- notebookGetTabLabelText nb sw
    label <- labelNew Nothing
    labelSetUseMarkup label True
    labelSetMarkup label   
        (if modified 
            then "<span foreground=\"red\">" ++ text ++ "</span>" 
            else text) 
    notebookSetTabLabel nb sw label  

fileSave :: Bool -> GhfAction
fileSave query = do
    window  <- readGhf window
    nb      <- readGhf notebook1
    bufs    <- readGhf buffers 
    mbnbufs <- lift $ do
        i   <- notebookGetCurrentPage nb
        mbp <- notebookGetNthPage nb i
        let currentBuffer = case i of
                -1 -> error "No page selected"
                n  -> bufs !! i
        let mbfn = fileName currentBuffer
        if isJust mbfn && query == False
            then do fileSave' currentBuffer $fromJust mbfn
                    return Nothing
            else do
                dialog <- fileChooserDialogNew
                                (Just $ "Save File")
                                (Just window)                   
                            FileChooserActionSave
                            [("gtk-cancel"     --buttons to display
                             ,ResponseCancel)  --you can use stock buttons
                             ,("gtk-save"
                             , ResponseAccept)]
                widgetShow dialog
                response <- dialogRun dialog
                widgetHide dialog
                mbFileName <- case response of
                        ResponseAccept ->       fileChooserGetFilename dialog
                        ResponseCancel ->       return Nothing
                        ResponseDeleteEvent->   return Nothing
                case mbFileName of
                    Nothing -> return Nothing
                    Just fn -> do
                        dfe <- doesFileExist fn 
                        resp <- if dfe
                            then do md <- messageDialogNew (Just window) []
                                            MessageQuestion
                                            ButtonsYesNo
                                            "File already exist. Overwrite?"
                                    resp <- dialogRun md
                                    widgetHide md
                                    return resp
                            else return ResponseYes
                        case resp of
                            ResponseYes -> do
                                fileSave' currentBuffer fn
                                let bn = takeFileName fn
                                let (ind,rbn) = figureOutBufferName bufs bn 0
                                label <- labelNew (Just rbn)
                                notebookSetTabLabel nb (fromJust mbp) label
                                return (Just (map (bufRename currentBuffer fn bn ind) bufs))
                            ResponseNo -> return Nothing
    case mbnbufs of
        Just nbufs ->modifyGhf_ (\ghf -> return (ghf{buffers = nbufs}))
        Nothing -> return ()
    where
        bufRename cb fn bn ind b  = if b == cb
                            then b{fileName = Just fn, bufferName = bn, addedIndex = ind}
                            else b
        fileSave' :: GhfBuffer -> FileName -> IO()
        fileSave' ghfBuf fn = do
            buf     <- textViewGetBuffer $ sourceView ghfBuf
            start   <- textBufferGetStartIter buf
            end     <- textBufferGetEndIter buf
            text    <- textBufferGetText buf start end True
            writeFile fn text
            textBufferSetModified buf False

fileNew :: GhfAction
fileNew = newTextBuffer "Unnamed" Nothing

fileClose :: GhfM Bool
fileClose = do
    ghfRef  <- ask
    window  <- readGhf window
    nb      <- readGhf notebook1
    bufs    <- readGhf buffers 
    mbbuf <- lift $ do
        i   <- notebookGetCurrentPage nb
        mbp <- notebookGetNthPage nb i
        let currentBuffer = case i of
                -1 -> error "No page selected"
                n  -> bufs !! i
        gtkbuf <- textViewGetBuffer $ sourceView currentBuffer
        modified <- textBufferGetModified gtkbuf
        if modified
            then do
                md <- messageDialogNew (Just window) []
                                            MessageQuestion
                                            ButtonsNone
                                            ("Save changes to document: "
                                                ++ realBufferName currentBuffer
                                                ++ "?")
                dialogAddButton md "_Save" ResponseYes
                dialogAddButton md "_Don't Save" ResponseNo
                dialogAddButton md "_Cancel" ResponseCancel
                resp <- dialogRun md
                widgetHide md
                case resp of
                    ResponseYes -> do   runReaderT (fileSave False) ghfRef 
                                        notebookRemovePage nb i
                                        return (Just currentBuffer)
                    ResponseCancel ->   return Nothing
                    ResponseNo -> do    notebookRemovePage nb i
                                        return (Just currentBuffer)
            else do
                notebookRemovePage nb i
                return (Just currentBuffer)
    case mbbuf of
        Just buf -> do
            modifyGhf_ (\ghf -> return (ghf{buffers = filter (/= buf) bufs}))
            return True
        Nothing -> return False

fileOpen :: GhfAction
fileOpen = do
    window <- readGhf window
    mbFileName <- lift $ do     
        dialog <- fileChooserDialogNew
                        (Just $ "Open File")             
                        (Just window)                   
                    FileChooserActionOpen              
                    [("gtk-cancel"                       
                    ,ResponseCancel)
                    ,("gtk-open"                                  
                    ,ResponseAccept)]
        widgetShow dialog
        response <- dialogRun dialog
        widgetHide dialog
        case response of
            ResponseAccept ->       fileChooserGetFilename dialog
            ResponseCancel ->       return Nothing
            ResponseDeleteEvent->   return Nothing
    case mbFileName of
        Nothing -> return ()
        Just fn -> newTextBuffer (takeFileName fn) (Just fn) 



