port module Main exposing (main)

import Browser
import ConfigField exposing (ConfigField(..))
import Cx
import Debug
import Dict as Dict exposing (Dict)
import Html
import Html.Styled exposing (..)
import Html.Styled.Attributes exposing (href, src, target, title, type_, value)
import Html.Styled.Events exposing (onClick, onInput, onSubmit)
import Http exposing (Error(..))
import Json.Decode as D
import Json.Encode as E
import List as List
import Maybe as Maybe
import Maybe.Extra as Maybe
import Platform.Cmd as Cmd
import RemoteData as RemoteData exposing (RemoteData(..), WebData)
import String as String
import Tuple exposing (first, second)



---- MODEL ----


type alias User =
    { id : Int
    , login : String
    , html_url : String
    , avatar_url : String
    }


type alias File =
    { filename : String
    , language : Maybe String
    }


type alias Gist =
    { id : String
    , description : Maybe String
    , html_url : String
    , files : Dict String File
    , public : Bool
    , created_at : String
    , updated_at : String
    , owner : User
    }


type Display
    = Grid
    | List


type Visible
    = Show
    | Hide


type alias PersistedConfig =
    { username : Maybe String
    , token : Maybe String
    }


type alias Token =
    ConfigField String


type alias Model =
    { gists : WebData (List Gist)
    , display : Display
    , showFiles : Bool
    , username : Maybe String
    , token : Token
    , search : String
    , sidebar : Visible
    }


authHeader : Maybe String -> Maybe Http.Header
authHeader =
    Maybe.map (Http.header "Authorization" << (\t -> "token " ++ t))


type alias Headers =
    Dict String String


expectJsonWithHeaders : (Result Http.Error ( a, Headers ) -> msg) -> D.Decoder a -> Http.Expect msg
expectJsonWithHeaders toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url ->
                    Err (Http.BadUrl url)

                Http.Timeout_ ->
                    Err Http.Timeout

                Http.NetworkError_ ->
                    Err Http.NetworkError

                Http.BadStatus_ metadata body ->
                    Err (Http.BadStatus metadata.statusCode)

                Http.GoodStatus_ { headers } body ->
                    case D.decodeString decoder body of
                        Ok value ->
                            Ok ( value, headers )

                        Err err ->
                            Err (Http.BadBody (D.errorToString err))


getGists : Maybe String -> String -> Cmd Msg
getGists token url =
    Http.request
        { method = "GET"
        , headers = Maybe.toList <| authHeader token
        , url = url
        , body = Http.emptyBody
        , expect =
            expectJsonWithHeaders
                (RemoteData.fromResult >> GotGists)
                (D.list gistD)
        , timeout = Nothing
        , tracker = Nothing
        }


init : ( Model, Cmd Msg )
init =
    ( { gists = NotAsked
      , display = Grid
      , showFiles = False
      , username = Nothing
      , token = Empty
      , search = ""
      , sidebar = Hide
      }
    , doLoadFromStorage ()
    )



---- -> JSON -> ----


gistD : D.Decoder Gist
gistD =
    D.map8 Gist
        (D.field "id" D.string)
        (D.field "description" <| D.nullable D.string)
        (D.field "html_url" D.string)
        (D.field "files" <| D.dict fileD)
        (D.field "public" D.bool)
        (D.field "created_at" D.string)
        (D.field "updated_at" D.string)
        (D.field "owner" userD)


userD : D.Decoder User
userD =
    D.map4 User
        (D.field "id" D.int)
        (D.field "login" D.string)
        (D.field "html_url" D.string)
        (D.field "avatar_url" D.string)


fileD : D.Decoder File
fileD =
    D.map2 File
        (D.field "filename" D.string)
        (D.field "language" <| D.nullable D.string)


persistedD : D.Decoder PersistedConfig
persistedD =
    D.map2 PersistedConfig
        (D.field "username" <| D.nullable D.string)
        (D.field "token" <| D.nullable D.string)


persistedE : PersistedConfig -> E.Value
persistedE { username, token } =
    E.object
        [ ( "username", maybeE E.string username )
        , ( "token", maybeE E.string token )
        ]


maybeE : (a -> E.Value) -> Maybe a -> E.Value
maybeE encoder =
    Maybe.unwrap E.null encoder


decodePersitedConfig : D.Value -> PersistedConfig
decodePersitedConfig =
    Result.withDefault { username = Nothing, token = Nothing } << D.decodeValue persistedD



---- UPDATE ----


type Msg
    = GotGists (WebData ( List Gist, Headers ))
    | LoadFromStorage PersistedConfig
      -- Search
    | ChangeSearch String
    | SearchGists
      -- Token
    | ChangeToken String
    | ClearToken
    | AddNewToken
    | SaveToken String
      -- UI
    | ChangeDisplay Display
    | ToggleFiles
    | ToggleSidebar


{-| nextUrl parses the "Link" header from GitHub's API to get the next url.
Docs: [developer.github.com/v3/gists](https://developer.github.com/v3/gists)

Transforms this:

    <https://api.github.com/user/8309423/gists?page=2>; rel="next", <https://api.github.com/user/8309423/gists?page=2>; rel="last"

    <https://api.github.com/user/8309423/gists?page=1>; rel="prev",
    <https://api.github.com/user/8309423/gists?page=3>; rel="next",
    <https://api.github.com/user/8309423/gists?page=5>; rel="last",
    <https://api.github.com/user/8309423/gists?page=1>; rel="first"

To this:

    https://api.github.com/user/8309423/gists?page=2

    https://api.github.com/user/8309423/gists?page=3

-}
nextUrl : Headers -> Maybe String
nextUrl =
    Dict.get "link"
        >> Maybe.filter hasNext
        >> Maybe.map (String.split "," >> List.filter hasNext)
        >> Maybe.andThen List.head
        >> Maybe.map (String.split ";")
        >> Maybe.andThen List.head
        >> Maybe.map (String.replace "<" "" >> String.replace ">" "")


hasNext : String -> Bool
hasNext =
    String.contains "rel=\"next\""


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotGists result ->
            let
                gists =
                    result
                        |> RemoteData.map first
                        |> RemoteData.map ((++) <| RemoteData.withDefault [] model.gists)
            in
            ( { model | gists = gists, search = "" }
            , RemoteData.unwrap Nothing (nextUrl << second) result
                |> Maybe.unwrap Cmd.none (getGists <| ConfigField.toMaybe model.token)
            )

        LoadFromStorage { username, token } ->
            ( { model
                | username = username
                , token = ConfigField.fromMaybe token
                , gists = Maybe.unwrap NotAsked (always Loading) username
              }
              -- TODO don't search if results are here already =/
            , Maybe.unwrap Cmd.none (getGists token << gistsUrl) username
            )

        -- Search
        ChangeSearch name ->
            ( { model | search = name }, Cmd.none )

        SearchGists ->
            ( { model | gists = Loading, username = Just model.search }
            , Cmd.batch
                [ getGists (ConfigField.toMaybe model.token) (gistsUrl model.search)
                , saveToStorage <|
                    persistedE
                        { token = ConfigField.toMaybe model.token
                        , username = Just model.search
                        }
                ]
            )

        -- Token
        ChangeToken token ->
            ( { model | token = Editing token }
            , Cmd.none
            )

        ClearToken ->
            ( { model | token = Empty }
            , saveToStorage <| persistedE { token = Nothing, username = model.username }
            )

        AddNewToken ->
            ( { model | token = Editing "" }
            , Cmd.none
            )

        SaveToken token ->
            ( { model | token = Saved token }
            , Cmd.batch
                [ getGists (Just token) (gistsUrl model.search)
                , saveToStorage <|
                    persistedE
                        { token = Just token, username = model.username }
                ]
            )

        -- UI ----------------------------------------------
        ChangeDisplay display ->
            ( { model | display = display }, Cmd.none )

        ToggleFiles ->
            ( { model | showFiles = not model.showFiles }, Cmd.none )

        ToggleSidebar ->
            ( { model | sidebar = showHide Hide Show model.sidebar }, Cmd.none )


gistsUrl : String -> String
gistsUrl username =
    "https://api.github.com/users/" ++ username ++ "/gists"



---- VIEW ----


showHide : a -> a -> Visible -> a
showHide onShow onHide x =
    case x of
        Show ->
            onShow

        Hide ->
            onHide


view : Model -> Html Msg
view model =
    div [ Cx.content ]
        [ Cx.global
        , renderControls model
        , renderTitle model.username
        , renderGists model
        , div [ Cx.menuToggle, onClick ToggleSidebar ] [ text "☰" ]
        , sidebar model.sidebar <| renderSidebarControls model
        , showHide
            (div [ Cx.sidebarBackdrop, onClick ToggleSidebar ] [])
            (text "")
            model.sidebar
        ]


renderSidebarControls : Model -> Html Msg
renderSidebarControls model =
    div []
        [ p [] [ text "GitHub Gist Token" ]
        , case model.token of
            Empty ->
                button
                    [ Cx.searchBtn, type_ "button", onClick AddNewToken ]
                    [ text "Add New Token" ]

            Editing token ->
                div []
                    [ input
                        [ Cx.searchInput
                        , onInput ChangeToken
                        , value token
                        ]
                        []
                    , button
                        [ Cx.searchBtn, type_ "button", onClick <| SaveToken token ]
                        [ text "Save" ]
                    ]

            Saved _ ->
                div []
                    [ button
                        [ Cx.searchBtn, type_ "button", onClick AddNewToken ]
                        [ text "Add New Token" ]
                    , button
                        [ Cx.searchBtn, type_ "button", onClick ClearToken ]
                        [ text "Clear" ]
                    ]
        ]


sidebar : Visible -> Html Msg -> Html Msg
sidebar visible content =
    div
        [ Cx.sidebar <| showHide Cx.sidebarOpen Cx.empty visible ]
        [ showHide content (text "") visible ]


renderTitle : Maybe String -> Html Msg
renderTitle mbUsername =
    case mbUsername of
        Just username ->
            h1 [] [ text <| username ++ " gists" ]

        Nothing ->
            h1 [] [ text "search gists by GitHub username" ]


renderControls : Model -> Html Msg
renderControls { display, showFiles, search, token } =
    div [ Cx.search ]
        [ form [ onSubmit SearchGists ]
            [ input [ Cx.searchInput, onInput ChangeSearch, value search ] []
            , button [ Cx.searchBtn, type_ "submit" ] [ text "Search" ]
            ]
        , renderToggleDisplayBtn display
        , renderToggleFiles showFiles
        ]


renderToggleDisplayBtn : Display -> Html Msg
renderToggleDisplayBtn display =
    let
        ( msg, label ) =
            case display of
                Grid ->
                    ( ChangeDisplay List, "☷" )

                List ->
                    ( ChangeDisplay Grid, "☰" )
    in
    button [ onClick msg ] [ text label ]


renderToggleFiles : Bool -> Html Msg
renderToggleFiles showFiles =
    let
        label =
            if showFiles then
                "Hide additional files"

            else
                "Show additional files"
    in
    button [ onClick ToggleFiles ] [ text label ]


renderError : Http.Error -> Html Msg
renderError err =
    case err of
        BadUrl str ->
            p [] [ text str ]

        Timeout ->
            p [] [ text "Request timed out." ]

        NetworkError ->
            div []
                [ p [] [ text "Looks like you are offline." ]
                , p [] [ text "Check your connection and try again." ]
                ]

        BadStatus code ->
            p [] [ text <| "Status: " ++ String.fromInt code ]

        BadBody msg ->
            p [] [ text <| "BadBody: " ++ msg ]


renderGists : Model -> Html Msg
renderGists { display, showFiles, gists } =
    let
        styles =
            case display of
                Grid ->
                    Cx.gists Cx.gistsGird

                List ->
                    Cx.gists Cx.gistsList
    in
    case gists of
        Success gs ->
            div
                [ styles ]
                (List.map (renderGist display showFiles) gs)

        Failure err ->
            div [] [ renderError err ]

        Loading ->
            div [] [ text "..." ]

        NotAsked ->
            text ""


renderGist : Display -> Bool -> Gist -> Html Msg
renderGist display showFiles { id, html_url, owner, files, public } =
    let
        filesLs =
            Dict.values files

        -- `gistName` is also the name of the first file (unless there's none)
        gistName =
            Maybe.unwrap id .filename <| List.head filesLs

        styles =
            case display of
                Grid ->
                    Cx.gistItem Cx.gistItemGrid

                List ->
                    Cx.gistItem Cx.gistItemList

        fsHtml =
            if showFiles then
                div []
                    << List.map renderFile
                    << Maybe.withDefault []
                <|
                    List.tail filesLs

            else
                text ""

        privateLabel =
            if public then
                text ""

            else
                span [] [ text " *" ]
    in
    div [ styles ]
        [ a
            [ Cx.gistItemLink
            , href html_url
            , target "_blank"
            , title gistName
            ]
            [ text <| "/" ++ gistName, privateLabel ]
        , fsHtml
        ]


renderFile : File -> Html Msg
renderFile file =
    div [] [ text file.filename ]



---- SUBSCRIPTIONS ----


subscriptions =
    loadFromStorage (LoadFromStorage << decodePersitedConfig)


port saveToStorage : E.Value -> Cmd msg


port loadFromStorage : (D.Value -> msg) -> Sub msg


port doLoadFromStorage : () -> Cmd msg



---- PROGRAM ----


main : Program () Model Msg
main =
    Browser.element
        { view = view >> toUnstyled
        , init = \_ -> init
        , update = update
        , subscriptions = \_ -> subscriptions
        }
