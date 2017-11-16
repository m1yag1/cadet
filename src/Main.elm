module Main exposing (..)

import AnimationFrame
import Date exposing (Date)
import Debug
import Dict exposing (Dict)
import Graph exposing (Graph)
import Html exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import Html.Lazy
import Http
import IntDict exposing (IntDict)
import Json.Decode as JD
import Json.Decode.Extra as JDE exposing ((|:))
import Mouse
import Navigation
import ParseInt
import Regex exposing (Regex)
import RouteUrl
import RouteUrl.Builder
import DOM
import Set
import Svg exposing (Svg)
import Svg.Attributes as SA
import Svg.Events as SE
import Svg.Lazy
import Task
import Time exposing (Time)
import Visualization.Shape as VS
import Hash
import GitHubGraph
import Backend exposing (Data, Me)
import ForceGraph as FG exposing (ForceGraph)
import StrictEvents


type alias Config =
    { initialDate : Time
    }


type alias Model =
    { config : Config
    , me : Maybe Me
    , page : Page
    , currentDate : Date
    , drag : Maybe (DragState CardSource)
    , data : Data
    , allCards : Dict GitHubGraph.ID Card
    , selectedCards : List GitHubGraph.ID
    , anticipatedCards : List GitHubGraph.ID
    , cardGraphs : List (ForceGraph (Node CardState))
    , computeGraph : Data -> List Card -> List (ForceGraph (Node CardState))
    }


type alias CardState =
    { currentDate : Date
    , selectedCards : List GitHubGraph.ID
    }


type alias Card =
    { isPullRequest : Bool
    , id : GitHubGraph.ID
    , url : String
    , number : Int
    , title : String
    , updatedAt : Date
    , author : Maybe GitHubGraph.User
    , labels : List GitHubGraph.Label
    , cards : List GitHubGraph.CardLocation
    , commentCount : Int
    , reactions : GitHubGraph.Reactions
    , score : Int
    , dragId : Maybe CardSource
    }


type alias CardDestination =
    { columnId : GitHubGraph.ID, afterId : Maybe GitHubGraph.ID }


type alias CardSource =
    { columnId : GitHubGraph.ID, cardId : GitHubGraph.ID }


type alias DragStartState =
    { pos : Mouse.Position
    , rect : DOM.Rectangle
    , x : Float
    , y : Float
    }


type Msg
    = Noop
    | SetPage Page
    | Tick Time
    | SetCurrentDate Date
    | DragStart CardSource DragStartState
    | DragAt Mouse.Position
    | DragOver (Maybe Msg)
    | DragEnd Mouse.Position
    | MoveCardAfter CardDestination
    | CardMoved GitHubGraph.ID (Result GitHubGraph.Error ())
    | CardsFetched (Model -> ( Model, Cmd Msg )) GitHubGraph.ID (Result Http.Error (List GitHubGraph.ProjectColumnCard))
    | MeFetched (Result Http.Error Me)
    | DataFetched (Result Http.Error Data)
    | SelectCard GitHubGraph.ID
    | DeselectCard GitHubGraph.ID
    | AnticipateCard GitHubGraph.ID
    | UnanticipateCard GitHubGraph.ID
    | SearchCards String
    | SelectAnticipatedCards
    | ClearSelectedCards


type Page
    = GlobalGraphPage
    | AllProjectsPage
    | ProjectPage String


type alias DragState a =
    { id : a
    , startPos : Mouse.Position
    , currentPos : Mouse.Position
    , rect : DOM.Rectangle
    , eleStartX : Float
    , eleStartY : Float
    , msg : Maybe Msg
    , purposeful : Bool
    , dropped : Bool
    , landed : Bool
    , neverLeft : Bool
    }


purposefulDragTreshold : Int
purposefulDragTreshold =
    10


decodeDragStartState : JD.Decoder DragStartState
decodeDragStartState =
    JD.succeed DragStartState
        |: Mouse.position
        |: JD.field "currentTarget" DOM.boundingClientRect
        |: JD.field "currentTarget" DOM.offsetLeft
        |: JD.field "currentTarget" DOM.offsetTop


onDragStart : (DragStartState -> msg) -> Html.Attribute msg
onDragStart msg =
    HE.on "mousedown" (JD.map msg decodeDragStartState)


main : RouteUrl.RouteUrlProgram Config Model Msg
main =
    RouteUrl.programWithFlags
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        , delta2url = delta2url
        , location2messages = location2messages
        }


delta2url : Model -> Model -> Maybe RouteUrl.UrlChange
delta2url a b =
    let
        withPageEntry =
            if a.page == b.page then
                identity
            else
                RouteUrl.Builder.newEntry

        withPagePath =
            case b.page of
                GlobalGraphPage ->
                    RouteUrl.Builder.replacePath []

                AllProjectsPage ->
                    RouteUrl.Builder.replacePath [ "projects" ]

                ProjectPage name ->
                    RouteUrl.Builder.replacePath [ "projects", name ]

        withSelection =
            RouteUrl.Builder.replaceHash (String.join "," b.selectedCards)

        builder =
            List.foldl (\f b -> f b) RouteUrl.Builder.builder [ withPageEntry, withPagePath, withSelection ]
    in
        Just (RouteUrl.Builder.toUrlChange builder)


location2messages : Navigation.Location -> List Msg
location2messages loc =
    let
        builder =
            RouteUrl.Builder.fromUrl loc.href

        path =
            RouteUrl.Builder.path builder

        hash =
            RouteUrl.Builder.hash builder

        page =
            case path of
                [] ->
                    SetPage GlobalGraphPage

                [ "projects" ] ->
                    SetPage AllProjectsPage

                [ "projects", name ] ->
                    SetPage (ProjectPage name)

                _ ->
                    SetPage GlobalGraphPage

        selection =
            List.map SelectCard (String.split "," hash)
    in
        page :: selection


type alias Position =
    { x : Float
    , y : Float
    }


type alias CardNodeRadii =
    { base : Float
    , withLabels : Float
    , withFlair : Float
    }


type alias NodeBounds =
    { x1 : Float
    , y1 : Float
    , x2 : Float
    , y2 : Float
    }


type alias Node a =
    { viewLower : Position -> a -> Svg Msg
    , viewUpper : Position -> a -> Svg Msg
    , bounds : Position -> NodeBounds
    , score : Int
    }


init : Config -> ( Model, Cmd Msg )
init config =
    ( { config = config
      , page = GlobalGraphPage
      , me = Nothing
      , data = Backend.emptyData
      , allCards = Dict.empty
      , selectedCards = []
      , anticipatedCards = []
      , currentDate = Date.fromTime config.initialDate
      , cardGraphs = []
      , computeGraph = computeReferenceGraph
      , drag = Nothing
      }
    , Cmd.batch
        [ Backend.fetchData DataFetched
        , Backend.fetchMe MeFetched
        ]
    )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every Time.second (SetCurrentDate << Date.fromTime)
        , if List.all FG.isCompleted model.cardGraphs then
            Sub.none
          else
            AnimationFrame.times Tick
        , case model.drag of
            Nothing ->
                Sub.none

            Just { dropped } ->
                if dropped then
                    Sub.none
                else
                    Sub.batch [ Mouse.moves DragAt, Mouse.ups DragEnd ]
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Noop ->
            ( model, Cmd.none )

        SetPage page ->
            let
                compute data cards =
                    case page of
                        ProjectPage name ->
                            computeReferenceGraph data (List.filter (isInProject name) cards)

                        _ ->
                            computeReferenceGraph data cards
            in
                ( { model
                    | page = page
                    , cardGraphs = compute model.data (Dict.values model.allCards)
                    , computeGraph = compute
                  }
                , Cmd.none
                )

        Tick _ ->
            ( { model
                | cardGraphs =
                    List.map
                        (\g ->
                            if FG.isCompleted g then
                                g
                            else
                                FG.tick g
                        )
                        model.cardGraphs
              }
            , Cmd.none
            )

        SetCurrentDate date ->
            ( { model | currentDate = date }, Cmd.none )

        DragStart id { pos, rect, x, y } ->
            ( { model
                | drag =
                    Just
                        { id = id
                        , startPos = pos
                        , currentPos = pos
                        , rect = rect
                        , eleStartX = x
                        , eleStartY = y
                        , msg = Nothing
                        , purposeful = False
                        , dropped = False
                        , landed = False
                        , neverLeft = True
                        }
              }
            , Cmd.none
            )

        DragAt pos ->
            let
                newDrag =
                    case model.drag of
                        Just drag ->
                            let
                                purposeful =
                                    abs (pos.x - drag.startPos.x)
                                        > purposefulDragTreshold
                                        || abs (pos.y - drag.startPos.y)
                                        > purposefulDragTreshold
                            in
                                Just
                                    { drag
                                        | currentPos = pos
                                        , purposeful = drag.purposeful || purposeful
                                    }

                        Nothing ->
                            Nothing
            in
                ( { model | drag = newDrag }, Cmd.none )

        DragEnd pos ->
            case model.drag of
                Just drag ->
                    let
                        newModel =
                            { model | drag = Just { drag | dropped = True } }
                    in
                        case drag.msg of
                            Just msg ->
                                update msg newModel

                            Nothing ->
                                ( { newModel | drag = Nothing }, Cmd.none )

                Nothing ->
                    ( { model | drag = Nothing }, Cmd.none )

        DragOver msg ->
            let
                newDrag =
                    case model.drag of
                        Just drag ->
                            Just { drag | msg = msg, neverLeft = False }

                        Nothing ->
                            Nothing
            in
                ( { model | drag = newDrag }, Cmd.none )

        MoveCardAfter dest ->
            case model.drag of
                Just drag ->
                    ( model, moveCard model dest drag.id.cardId )

                Nothing ->
                    ( model, Cmd.none )

        CardMoved col (Ok ()) ->
            case model.drag of
                Just drag ->
                    let
                        finishDrag model =
                            ( { model | drag = Nothing }, Cmd.none )

                        refresh landed id model =
                            ( { model | drag = Just { drag | landed = landed } }, Backend.refreshCards id (CardsFetched finishDrag id) )
                    in
                        if drag.id.columnId == col then
                            refresh False col model
                        else
                            ( model, Backend.refreshCards col (CardsFetched (refresh True drag.id.columnId) col) )

                Nothing ->
                    ( model, Cmd.none )

        CardMoved col (Err msg) ->
            flip always (Debug.log "failed to move card" msg) <|
                ( model, Cmd.none )

        CardsFetched cb col (Ok cards) ->
            let
                data =
                    model.data
            in
                cb { model | data = { data | cards = Dict.insert col cards data.cards } }

        CardsFetched _ col (Err msg) ->
            flip always (Debug.log "failed to refresh cards" msg) <|
                ( model, Cmd.none )

        SearchCards "" ->
            ( { model | anticipatedCards = [] }, Cmd.none )

        SearchCards query ->
            let
                cardMatch { id, title } =
                    if String.contains (String.toLower query) (String.toLower title) then
                        Just id
                    else
                        Nothing

                foundCards =
                    List.filterMap cardMatch (Dict.values model.allCards)
            in
                ( { model | anticipatedCards = foundCards }, Cmd.none )

        SelectAnticipatedCards ->
            ( { model
                | anticipatedCards = []
                , selectedCards = model.selectedCards ++ model.anticipatedCards
              }
            , Cmd.none
            )

        SelectCard id ->
            ( { model
                | selectedCards =
                    if List.member id model.selectedCards then
                        model.selectedCards
                    else
                        model.selectedCards ++ [ id ]
              }
            , Cmd.none
            )

        ClearSelectedCards ->
            ( { model | selectedCards = [] }, Cmd.none )

        DeselectCard id ->
            ( { model
                | selectedCards = List.filter ((/=) id) model.selectedCards
              }
            , Cmd.none
            )

        AnticipateCard id ->
            ( { model | anticipatedCards = id :: model.anticipatedCards }
            , Cmd.none
            )

        UnanticipateCard id ->
            ( { model | anticipatedCards = List.filter ((/=) id) model.anticipatedCards }, Cmd.none )

        MeFetched (Ok me) ->
            ( { model | me = Just me }, Cmd.none )

        MeFetched (Err msg) ->
            flip always (Debug.log "error fetching self" msg) <|
                ( model, Cmd.none )

        DataFetched (Ok data) ->
            let
                withIssues =
                    Dict.foldl (\_ is cards -> List.foldl (\i -> Dict.insert i.id (issueCard i)) cards is) Dict.empty data.issues

                withPRs =
                    Dict.foldl (\_ ps cards -> List.foldl (\p -> Dict.insert p.id (prCard p)) cards ps) withIssues data.prs

                allCards =
                    withPRs
            in
                ( { model
                    | data = data
                    , allCards = allCards
                    , cardGraphs = model.computeGraph data (Dict.values allCards)
                  }
                , Cmd.none
                )

        DataFetched (Err msg) ->
            flip always (Debug.log "error fetching data" msg) <|
                ( model, Cmd.none )


issueCard : GitHubGraph.Issue -> Card
issueCard ({ id, url, number, title, updatedAt, author, labels, cards, commentCount, reactions } as issue) =
    { isPullRequest = False
    , id = id
    , url = url
    , number = number
    , title = title
    , updatedAt = updatedAt
    , author = author
    , labels = labels
    , cards = cards
    , commentCount = commentCount
    , reactions = reactions
    , score = GitHubGraph.pullRequestScore issue
    , dragId = Nothing
    }


prCard : GitHubGraph.PullRequest -> Card
prCard ({ id, url, number, title, updatedAt, author, labels, cards, commentCount, reactions } as pr) =
    { isPullRequest = True
    , id = id
    , url = url
    , number = number
    , title = title
    , updatedAt = updatedAt
    , author = author
    , labels = labels
    , cards = cards
    , commentCount = commentCount
    , reactions = reactions
    , score = GitHubGraph.pullRequestScore pr
    , dragId = Nothing
    }


view : Model -> Html Msg
view model =
    let
        anticipatedCards =
            List.map (viewCardEntry model) <|
                List.filterMap (flip Dict.get model.allCards) <|
                    List.filter (not << flip List.member model.selectedCards) model.anticipatedCards

        selectedCards =
            List.map (viewCardEntry model) <|
                List.filterMap (flip Dict.get model.allCards) model.selectedCards

        sidebarCards =
            selectedCards ++ anticipatedCards
    in
        Html.div [ HA.class "cadet" ]
            [ Html.div [ HA.class "main-page" ]
                [ Html.div [ HA.class "page-content" ]
                    [ case model.page of
                        GlobalGraphPage ->
                            viewGlobalGraphPage model

                        AllProjectsPage ->
                            viewAllProjectsPage model

                        ProjectPage id ->
                            viewProjectPage model id
                    ]
                , Html.div [ HA.class "page-sidebar" ]
                    [ if List.isEmpty sidebarCards then
                        Html.div [ HA.class "no-cards" ]
                            [ Html.text "no cards selected" ]
                      else
                        Html.div [ HA.class "cards" ] sidebarCards
                    ]
                ]
            , viewNavBar model
            ]


viewGlobalGraphPage : Model -> Html Msg
viewGlobalGraphPage model =
    Html.div [ HA.class "spatial-graph" ] <|
        List.map (Html.Lazy.lazy (viewGraph model)) model.cardGraphs


viewNavBar : Model -> Html Msg
viewNavBar model =
    Html.div [ HA.class "bottom-bar" ]
        [ Html.div [ HA.class "nav" ]
            [ case model.me of
                Nothing ->
                    Html.a [ HA.class "button user-info", HA.href "/auth/github" ]
                        [ Html.span [ HA.class "log-in-icon octicon octicon-sign-in" ] []
                        , Html.text "log in"
                        ]

                Just { user } ->
                    Html.a [ HA.class "button user-info", HA.href user.url ]
                        [ Html.img [ HA.class "user-avatar", HA.src user.avatar ] []
                        , Html.text user.login
                        ]
            , Html.a [ HA.class "button", HA.href "/", StrictEvents.onLeftClick (SetPage GlobalGraphPage) ]
                [ Html.span [ HA.class "octicon octicon-globe" ] []
                ]
            , Html.a [ HA.class "button", HA.href "/projects", StrictEvents.onLeftClick (SetPage AllProjectsPage) ]
                [ Html.span [ HA.class "octicon octicon-list-unordered" ] []
                ]
            ]
        , viewSearch
        ]


type alias ProjectState =
    { id : GitHubGraph.ID
    , name : String
    , backlog : GitHubGraph.ProjectColumn
    , inFlight : GitHubGraph.ProjectColumn
    , done : GitHubGraph.ProjectColumn
    , problemSpace : List GitHubGraph.ProjectColumn
    }


selectStatefulProject : GitHubGraph.Project -> Maybe ProjectState
selectStatefulProject project =
    let
        findColumn name =
            case List.filter ((==) name << .name) project.columns of
                [ col ] ->
                    Just col

                _ ->
                    Nothing

        backlog =
            findColumn "Backlog"

        inFlight =
            findColumn "In Flight"

        done =
            findColumn "Done"

        rest =
            List.filter (not << flip List.member [ "Backlog", "In Flight", "Done" ] << .name) project.columns
    in
        case ( backlog, inFlight, done ) of
            ( Just b, Just i, Just d ) ->
                Just
                    { id = project.id
                    , name = project.name
                    , backlog = b
                    , inFlight = i
                    , done = d
                    , problemSpace = rest
                    }

            _ ->
                Nothing


viewAllProjectsPage : Model -> Html Msg
viewAllProjectsPage model =
    let
        statefulProjects =
            List.filterMap selectStatefulProject model.data.projects
    in
        Html.div [ HA.class "project-table" ]
            [ Html.div [ HA.class "project-name-columns" ]
                [ Html.div [ HA.class "column name-column" ]
                    []
                , Html.div [ HA.class "column backlog-column" ]
                    [ Html.h4 [] [ Html.text "Backlog" ] ]
                , Html.div [ HA.class "column in-flight-column" ]
                    [ Html.h4 [] [ Html.text "In Flight" ] ]
                , Html.div [ HA.class "column done-column" ]
                    [ Html.h4 [] [ Html.text "Done" ] ]
                ]
            , Html.div [ HA.class "projects" ]
                (List.map (viewProject model) statefulProjects)
            ]


viewProject : Model -> ProjectState -> Html Msg
viewProject model { name, backlog, inFlight, done } =
    Html.div [ HA.class "project" ]
        [ Html.div [ HA.class "project-columns" ]
            [ Html.div [ HA.class "column name-column" ]
                [ Html.h4 []
                    [ Html.a [ HA.href ("/projects/" ++ name), StrictEvents.onLeftClick (SetPage (ProjectPage name)) ]
                        [ Html.text name ]
                    ]
                ]
            , Html.div [ HA.class "column backlog-column" ]
                [ viewProjectColumn model (Just 3) backlog ]
            , Html.div [ HA.class "column in-flight-column" ]
                [ viewProjectColumn model Nothing inFlight ]
            , Html.div [ HA.class "column done-column" ]
                [ viewProjectColumn model Nothing done ]
            ]
        , Html.div [ HA.class "project-spacer-columns" ]
            [ Html.div [ HA.class "column name-column" ]
                []
            , Html.div [ HA.class "column backlog-column" ]
                []
            , Html.div [ HA.class "column in-flight-column" ]
                []
            , Html.div [ HA.class "column done-column" ]
                []
            ]
        ]


viewDropArea : Model -> Maybe CardSource -> Maybe Msg -> Html Msg
viewDropArea model dragId mmsg =
    let
        dragEvents =
            case model.drag of
                Just { purposeful, dropped } ->
                    if purposeful && not dropped then
                        [ HE.onMouseEnter (DragOver mmsg)
                        , HE.onMouseLeave (DragOver Nothing)
                        ]
                    else
                        []

                Nothing ->
                    []

        isActive =
            case model.drag of
                Nothing ->
                    False

                Just { purposeful, dropped } ->
                    purposeful && not dropped

        isOver =
            case model.drag of
                Nothing ->
                    False

                Just drag ->
                    case drag.msg of
                        Just _ ->
                            drag.msg == mmsg && not (drag.dropped && drag.landed)

                        _ ->
                            drag.neverLeft && drag.purposeful && dragId == Just drag.id
    in
        Html.div
            ([ HA.classList
                [ ( "drop-area", True )
                , ( "active", isActive )
                , ( "never-left", Maybe.withDefault False (Maybe.map .neverLeft model.drag) )
                , ( "over", isOver )
                ]
             , HA.style <|
                case model.drag of
                    Nothing ->
                        []

                    Just drag ->
                        if isOver then
                            -- drop-area height + 2 * card-margin
                            [ ( "height", toString (60 + (2 * 8) + drag.rect.height) ++ "px" ) ]
                        else
                            []
             ]
                ++ dragEvents
            )
            []


viewProjectColumn : Model -> Maybe Int -> GitHubGraph.ProjectColumn -> Html Msg
viewProjectColumn model mlimit col =
    let
        cards =
            Maybe.withDefault [] (Dict.get col.id model.data.cards)

        limit =
            Maybe.withDefault identity (Maybe.map List.take mlimit)
    in
        Html.div [ HA.class "cards" ] <|
            viewDropArea model Nothing (Just (MoveCardAfter { columnId = col.id, afterId = Nothing }))
                :: List.concat (limit (List.filterMap (viewProjectColumnCard model col) cards))


viewProjectColumnCard : Model -> GitHubGraph.ProjectColumn -> GitHubGraph.ProjectColumnCard -> Maybe (List (Html Msg))
viewProjectColumnCard model col ghCard =
    case ( ghCard.note, ghCard.itemID ) of
        ( Just n, Nothing ) ->
            -- TODO: show note cards!
            Nothing

        ( Nothing, Just i ) ->
            case Dict.get i model.allCards of
                Just card ->
                    let
                        dragId =
                            Just { columnId = col.id, cardId = ghCard.id }

                        dragTarget =
                            { columnId = col.id, afterId = Just ghCard.id }
                    in
                        Just
                            [ viewCard model { card | dragId = dragId }
                            , viewDropArea model dragId (Just (MoveCardAfter dragTarget))
                            ]

                Nothing ->
                    -- closed issue
                    Nothing

        _ ->
            Debug.crash "impossible"


viewProjectPage : Model -> String -> Html Msg
viewProjectPage model name =
    let
        statefulProjects =
            List.filterMap selectStatefulProject model.data.projects

        mproject =
            List.head <|
                List.filter ((==) name << .name) statefulProjects
    in
        case mproject of
            Just project ->
                viewSingleProject model project

            Nothing ->
                Html.text "project not found"


viewSingleProject : Model -> ProjectState -> Html Msg
viewSingleProject model { id, name, backlog, inFlight, done } =
    Html.div [ HA.class "project single" ]
        [ Html.div [ HA.class "project-columns" ]
            [ Html.div [ HA.class "column name-column" ]
                [ Html.h4 [] [ Html.text name ] ]
            , Html.div [ HA.class "column done-column" ]
                [ viewProjectColumn model Nothing done ]
            , Html.div [ HA.class "column in-flight-column" ]
                [ viewProjectColumn model Nothing inFlight ]
            , Html.div [ HA.class "column backlog-column" ]
                [ viewProjectColumn model Nothing backlog ]
            ]
        , Html.div [ HA.class "spatial-graph" ] <|
            List.map (Html.Lazy.lazy (viewGraph model)) model.cardGraphs
        ]


viewSearch : Html Msg
viewSearch =
    Html.div [ HA.class "card-search" ]
        [ Html.span
            [ HE.onClick ClearSelectedCards
            , HA.class "octicon octicon-x clear-selected"
            ]
            [ Html.text "" ]
        , Html.form [ HE.onSubmit SelectAnticipatedCards ]
            [ Html.input [ HE.onInput SearchCards, HA.placeholder "filter cards" ] [] ]
        ]


computeReferenceGraph : Data -> List Card -> List (ForceGraph (Node CardState))
computeReferenceGraph data cards =
    let
        cardEdges =
            Dict.foldl
                (\idStr sourceIds refs ->
                    let
                        id =
                            Hash.hash idStr
                    in
                        List.map
                            (\sourceId ->
                                { from = Hash.hash sourceId
                                , to = id
                                , label = ()
                                }
                            )
                            sourceIds
                            ++ refs
                )
                []
                data.references

        cardNodeThunks =
            List.map (\card -> Graph.Node (Hash.hash card.id) (cardNode card)) cards

        applyWithContext ({ node, incoming, outgoing } as nc) =
            let
                context =
                    { incoming = incoming, outgoing = outgoing }
            in
                { nc | node = { node | label = node.label context } }

        graph =
            Graph.mapContexts applyWithContext <|
                Graph.fromNodesAndEdges
                    cardNodeThunks
                    cardEdges
    in
        subGraphs graph
            |> List.map FG.fromGraph
            |> List.sortWith graphCompare
            |> List.reverse


graphCompare : ForceGraph (Node a) -> ForceGraph (Node a) -> Order
graphCompare a b =
    case compare (Graph.size a.graph) (Graph.size b.graph) of
        EQ ->
            let
                graphScore =
                    List.foldl (+) 0 << List.map (.label >> .value >> .score) << Graph.nodes
            in
                compare (graphScore a.graph) (graphScore b.graph)

        x ->
            x


viewGraph : Model -> ForceGraph (Node CardState) -> Html Msg
viewGraph model { graph } =
    let
        nodeContexts =
            Graph.fold (::) [] graph

        bounds =
            List.map nodeBounds nodeContexts

        padding =
            10

        minX =
            List.foldl (\{ x1 } acc -> min x1 acc) 999999 bounds - padding

        minY =
            List.foldl (\{ y1 } acc -> min y1 acc) 999999 bounds - padding

        maxX =
            List.foldl (\{ x2 } acc -> max x2 acc) 0 bounds + padding

        maxY =
            List.foldl (\{ y2 } acc -> max y2 acc) 0 bounds + padding

        width =
            maxX - minX

        height =
            maxY - minY

        links =
            (List.map (Svg.Lazy.lazy <| linkPath graph) (Graph.edges graph))

        state =
            { currentDate = model.currentDate
            , selectedCards = model.selectedCards
            }

        ( flairs, nodes ) =
            Graph.fold (viewNodeLowerUpper state) ( [], [] ) graph
    in
        Svg.svg
            [ SA.width (toString width ++ "px")
            , SA.height (toString height ++ "px")
            , SA.viewBox (toString minX ++ " " ++ toString minY ++ " " ++ toString width ++ " " ++ toString height)
            ]
            [ Svg.g [ SA.class "links" ] links
            , Svg.g [ SA.class "lower" ] flairs
            , Svg.g [ SA.class "upper" ] nodes
            ]


viewNodeLowerUpper : CardState -> Graph.NodeContext (FG.ForceNode (Node CardState)) () -> ( List (Svg Msg), List (Svg Msg) ) -> ( List (Svg Msg), List (Svg Msg) )
viewNodeLowerUpper state { node } ( fs, ns ) =
    let
        pos =
            { x = node.label.x, y = node.label.y }
    in
        ( Svg.Lazy.lazy2 node.label.value.viewLower pos state :: fs
        , Svg.Lazy.lazy2 node.label.value.viewUpper pos state :: ns
        )


linkPath : Graph (FG.ForceNode n) () -> Graph.Edge () -> Svg Msg
linkPath graph edge =
    let
        source =
            case Maybe.map (.node >> .label) (Graph.get edge.from graph) of
                Just { x, y } ->
                    { x = x, y = y }

                Nothing ->
                    { x = 0, y = 0 }

        target =
            case Maybe.map (.node >> .label) (Graph.get edge.to graph) of
                Just { x, y } ->
                    { x = x, y = y }

                Nothing ->
                    { x = 0, y = 0 }
    in
        Svg.line
            [ SA.strokeWidth "4"
            , SA.stroke "rgba(0,0,0,.2)"
            , SA.x1 (toString source.x)
            , SA.y1 (toString source.y)
            , SA.x2 (toString target.x)
            , SA.y2 (toString target.y)
            ]
            []


type alias GraphContext =
    { incoming : IntDict ()
    , outgoing : IntDict ()
    }


issueRadius : Card -> GraphContext -> Float
issueRadius card { incoming, outgoing } =
    15 + ((toFloat (IntDict.size incoming) / 2) + toFloat (IntDict.size outgoing * 2))


issueRadiusWithLabels : Card -> GraphContext -> Float
issueRadiusWithLabels card context =
    issueRadius card context + 3


flairRadiusBase : Float
flairRadiusBase =
    16


issueRadiusWithFlair : Card -> GraphContext -> Float
issueRadiusWithFlair card context =
    let
        reactionCounts =
            List.map .count card.reactions

        highestFlair =
            List.foldl (\num acc -> max num acc) 0 (card.commentCount :: reactionCounts)
    in
        issueRadiusWithLabels card context + flairRadiusBase + toFloat highestFlair


cardNode : Card -> GraphContext -> Node CardState
cardNode card context =
    let
        flair =
            nodeFlairArcs card context

        labels =
            nodeLabelArcs card context

        radii =
            { base = issueRadius card context
            , withLabels = issueRadiusWithLabels card context
            , withFlair = issueRadiusWithFlair card context
            }
    in
        { viewLower = viewCardNodeFlair card flair
        , viewUpper = viewCardNode card radii labels
        , bounds =
            \{ x, y } ->
                { x1 = x - radii.withFlair
                , y1 = y - radii.withFlair
                , x2 = x + radii.withFlair
                , y2 = y + radii.withFlair
                }
        , score = card.score
        }


renderCardNode : Card -> CardState -> List (Svg Msg)
renderCardNode card state =
    []


nodeFlairArcs : Card -> GraphContext -> List (Svg Msg)
nodeFlairArcs card context =
    let
        radius =
            issueRadiusWithLabels card context

        reactionTypeEmoji type_ =
            case type_ of
                GitHubGraph.ReactionTypeThumbsUp ->
                    "👍"

                GitHubGraph.ReactionTypeThumbsDown ->
                    "👎"

                GitHubGraph.ReactionTypeLaugh ->
                    "😄"

                GitHubGraph.ReactionTypeConfused ->
                    "😕"

                GitHubGraph.ReactionTypeHeart ->
                    "💖"

                GitHubGraph.ReactionTypeHooray ->
                    "🎉"

        emojiReactions =
            flip List.map card.reactions <|
                \{ type_, count } ->
                    ( reactionTypeEmoji type_, count )

        flairs =
            List.filter (Tuple.second >> flip (>) 0) <|
                (( "💬", card.commentCount ) :: emojiReactions)

        reactionSegment i ( _, count ) =
            let
                segments =
                    VS.pie
                        { startAngle = 0
                        , endAngle = 2 * pi
                        , padAngle = 0.03
                        , sortingFn = \_ _ -> EQ
                        , valueFn = always 1.0
                        , innerRadius = radius
                        , outerRadius = radius + flairRadiusBase + toFloat count
                        , cornerRadius = 3
                        , padRadius = 0
                        }
                        (List.repeat (List.length flairs) 1)
            in
                case List.take 1 (List.drop i segments) of
                    [ s ] ->
                        s

                    _ ->
                        Debug.crash "impossible"

        innerCentroid arc =
            let
                r =
                    arc.innerRadius + 10

                a =
                    (arc.startAngle + arc.endAngle) / 2 - pi / 2
            in
                ( cos a * r, sin a * r )
    in
        flip List.indexedMap flairs <|
            \i (( emoji, count ) as reaction) ->
                let
                    arc =
                        reactionSegment i reaction
                in
                    Svg.g [ SA.class "reveal" ]
                        [ Svg.path
                            [ SA.d (VS.arc arc)
                            , SA.fill "#fff"
                            ]
                            []
                        , Svg.text_
                            [ SA.transform ("translate" ++ toString (innerCentroid arc))
                            , SA.textAnchor "middle"
                            , SA.alignmentBaseline "middle"
                            , SA.class "hidden"
                            ]
                            [ Svg.text emoji
                            ]
                        ]


nodeLabelArcs : Card -> GraphContext -> List (Svg Msg)
nodeLabelArcs card context =
    let
        radius =
            issueRadius card context

        labelSegments =
            VS.pie
                { startAngle = 0
                , endAngle = 2 * pi
                , padAngle = 0
                , sortingFn = \_ _ -> EQ
                , valueFn = always 1.0
                , innerRadius = radius
                , outerRadius = radius + 3
                , cornerRadius = 0
                , padRadius = 0
                }
                (List.repeat (List.length card.labels) 1)
    in
        List.map2
            (\arc label ->
                Svg.path
                    [ SA.d (VS.arc arc)
                    , SA.fill ("#" ++ label.color)
                    ]
                    []
            )
            labelSegments
            card.labels


viewCardNodeFlair : Card -> List (Svg Msg) -> Position -> CardState -> Svg Msg
viewCardNodeFlair card flair { x, y } state =
    Svg.g
        [ SA.opacity (toString (activityOpacity state.currentDate card.updatedAt * 0.75))
        , SA.transform ("translate(" ++ toString x ++ ", " ++ toString y ++ ")")
        ]
        flair


activityOpacity : Date -> Date -> Float
activityOpacity now date =
    let
        daysSinceLastUpdate =
            (Date.toTime now / (24 * Time.hour)) - (Date.toTime date / (24 * Time.hour))
    in
        if daysSinceLastUpdate <= 1 then
            1
        else if daysSinceLastUpdate <= 2 then
            0.75
        else if daysSinceLastUpdate <= 7 then
            0.5
        else
            0.25


viewCardNode : Card -> CardNodeRadii -> List (Svg Msg) -> Position -> CardState -> Svg Msg
viewCardNode card radii labels { x, y } state =
    let
        isSelected =
            List.member card.id state.selectedCards

        circleWithNumber =
            if not card.isPullRequest then
                [ Svg.circle
                    [ SA.r (toString radii.base)
                    , SA.fill "#fff"
                    ]
                    []
                , Svg.text_
                    [ SA.textAnchor "middle"
                    , SA.alignmentBaseline "middle"
                    , SA.class "issue-number"
                    ]
                    [ Svg.text (toString card.number)
                    ]
                ]
            else
                [ Svg.circle
                    [ SA.r (toString radii.base)
                    , SA.class "pr-circle"
                    ]
                    []
                , Svg.text_
                    [ SA.textAnchor "middle"
                    , SA.alignmentBaseline "middle"
                    , SA.fill "#fff"
                    ]
                    [ Svg.text (toString card.number)
                    ]
                ]
    in
        Svg.g
            [ SA.transform ("translate(" ++ toString x ++ ", " ++ toString y ++ ")")
            , SE.onMouseOver (AnticipateCard card.id)
            , SE.onMouseOut (UnanticipateCard card.id)
            , SE.onClick
                (if isSelected then
                    DeselectCard card.id
                 else
                    SelectCard card.id
                )
            ]
            (circleWithNumber ++ labels)


viewCardEntry : Model -> Card -> Html Msg
viewCardEntry model card =
    let
        anticipated =
            isAnticipated model card
    in
        Html.div [ HA.class "card-controls" ]
            [ Html.div [ HA.class "card-buttons" ]
                [ if not anticipated then
                    Html.span
                        [ HE.onClick (DeselectCard card.id)
                        , HA.class "octicon octicon-x"
                        ]
                        [ Html.text "" ]
                  else
                    Html.text ""
                ]
            , viewCard model card
            ]


isInProject : String -> Card -> Bool
isInProject name card =
    List.member name (List.map (.project >> .name) card.cards)


inColumn : String -> Card -> Bool
inColumn name card =
    List.member name (List.filterMap (Maybe.map .name << .column) card.cards)


isInFlight : Card -> Bool
isInFlight =
    inColumn "In Flight"


isAnticipated : Model -> Card -> Bool
isAnticipated model card =
    List.member card.id model.anticipatedCards && not (List.member card.id model.selectedCards)


isDone : Card -> Bool
isDone =
    inColumn "Done"


isBacklog : Card -> Bool
isBacklog =
    inColumn "Backlog"


viewCard : Model -> Card -> Html Msg
viewCard model card =
    let
        moveStyle =
            case ( card.dragId, model.drag ) of
                ( Just dragId, Just { purposeful, id, eleStartX, eleStartY, startPos, currentPos } ) ->
                    if purposeful && id == dragId then
                        [ ( "box-shadow", "0 3px 6px rgba(0,0,0,0.24)" )
                        , ( "position", "absolute" )
                        , ( "top", toString (eleStartY + toFloat (currentPos.y - startPos.y)) ++ "px" )
                        , ( "left", toString (eleStartX + toFloat (currentPos.x - startPos.x)) ++ "px" )
                        , ( "z-index", "2" )
                        ]
                    else
                        []

                _ ->
                    []

        dragEvents =
            case card.dragId of
                Just dragId ->
                    [ onDragStart (DragStart dragId) ]

                Nothing ->
                    []
    in
        Html.div
            ([ HA.classList
                [ ( "card", True )
                , ( "draggable", card.dragId /= Nothing )
                , ( "dragging", not <| List.isEmpty moveStyle )
                , ( "in-flight", isInFlight card )
                , ( "done", isDone card )
                , ( "backlog", isBacklog card )
                , ( "anticipated", isAnticipated model card )
                ]
             , HE.onClick (SelectCard card.id)
             , HA.style moveStyle
             ]
                ++ dragEvents
            )
            [ Html.div [ HA.class "card-info" ]
                [ Html.div [ HA.class "card-actors" ] <|
                    List.map (viewCardActor model) (recentActors model card)
                , Html.a
                    [ HA.href card.url
                    , HA.target "_blank"
                    , HA.class "card-title"
                    , HA.draggable "false"
                    ]
                    [ Html.text card.title
                    ]
                , Html.span [ HA.class "card-labels" ] <|
                    List.map viewLabel card.labels
                , Html.div [ HA.class "card-meta" ]
                    [ Html.a
                        [ HA.href card.url
                        , HA.target "_blank"
                        , HA.draggable "false"
                        ]
                        [ Html.text ("#" ++ toString card.number) ]
                    , Html.text " "
                    , Html.text "opened by "
                    , case card.author of
                        Just user ->
                            Html.a
                                [ HA.href user.url
                                , HA.target "_blank"
                                , HA.draggable "false"
                                ]
                                [ Html.text user.login ]

                        _ ->
                            Html.text "(deleted user)"
                    ]
                ]
            ]


recentActors : Model -> Card -> List Backend.ActorEvent
recentActors model card =
    Dict.get card.id model.data.actors
        |> Maybe.withDefault []
        |> List.reverse
        |> List.take 3
        |> List.reverse


hexRegex : Regex
hexRegex =
    Regex.regex "([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})"


hexBrightness : Int -> Int
hexBrightness h =
    case compare h (0xFF // 2) of
        LT ->
            -1

        EQ ->
            0

        GT ->
            1


colorIsLight : String -> Bool
colorIsLight hex =
    let
        matches =
            List.head <| Regex.find (Regex.AtMost 1) hexRegex hex
    in
        case Maybe.map .submatches matches of
            Just [ Just h1s, Just h2s, Just h3s ] ->
                case List.map ParseInt.parseIntHex [ h1s, h2s, h3s ] of
                    [ Ok h1, Ok h2, Ok h3 ] ->
                        if (hexBrightness h1 + hexBrightness h2 + hexBrightness h3) > 0 then
                            True
                        else
                            False

                    _ ->
                        Debug.crash "invalid hex"

            _ ->
                Debug.crash "invalid hex"


viewLabel : GitHubGraph.Label -> Html Msg
viewLabel { name, color } =
    Html.span
        [ HA.class "card-label"
        , HA.style
            [ ( "background-color", "#" ++ color )
            , ( "color"
              , if colorIsLight color then
                    -- GitHub appears to pre-compute a hex code, but this seems to be
                    -- pretty much all it's doing
                    "rgba(0, 0, 0, .8)"
                else
                    -- for darker backgrounds they just do white
                    "#fff"
              )
            ]
        ]
        [ Html.span [ HA.class "card-label-text" ]
            [ Html.text name ]
        ]


viewCardActor : Model -> Backend.ActorEvent -> Html Msg
viewCardActor model { createdAt, actor } =
    Html.img
        [ HA.class "card-actor"
        , HA.style [ ( "opacity", toString (activityOpacity model.currentDate createdAt) ) ]
        , HA.src (actor.avatar ++ "&s=88")
        , HA.draggable "false"
        ]
        []


isOrgMember : Maybe (List GitHubGraph.User) -> GitHubGraph.User -> Bool
isOrgMember users user =
    List.any (\x -> x.id == user.id) (Maybe.withDefault [] users)


subEdges : List (Graph.Edge e) -> List (List (Graph.Edge e))
subEdges edges =
    let
        edgesContains nodeId =
            List.any (\{ from, to } -> from == nodeId || to == nodeId)

        go edges acc =
            case edges of
                [] ->
                    acc

                edge :: rest ->
                    let
                        hasFrom =
                            List.filter (edgesContains edge.from) acc

                        hasTo =
                            List.filter (edgesContains edge.to) acc

                        hasNeither =
                            List.filter (\es -> not (edgesContains edge.from es) && not (edgesContains edge.to es)) acc
                    in
                        case ( hasFrom, hasTo ) of
                            ( [], [] ) ->
                                go rest ([ edge ] :: acc)

                            ( [ sub1 ], [ sub2 ] ) ->
                                go rest ((edge :: (sub1 ++ sub2)) :: hasNeither)

                            ( [ sub1 ], [] ) ->
                                go rest ((edge :: sub1) :: hasNeither)

                            ( [], [ sub2 ] ) ->
                                go rest ((edge :: sub2) :: hasNeither)

                            _ ->
                                Debug.crash "impossible"
    in
        go edges []


subGraphs : Graph n e -> List (Graph n e)
subGraphs graph =
    let
        singletons =
            Graph.fold
                (\nc ncs ->
                    if IntDict.isEmpty nc.incoming && IntDict.isEmpty nc.outgoing then
                        nc :: ncs
                    else
                        ncs
                )
                []
                graph

        singletonGraphs =
            List.map (flip Graph.insert Graph.empty) singletons

        subEdgeNodes =
            List.foldl (\edge set -> Set.insert edge.from (Set.insert edge.to set)) Set.empty

        connectedGraphs =
            graph
                |> Graph.edges
                |> subEdges
                |> List.map (flip Graph.inducedSubgraph graph << Set.toList << subEdgeNodes)
    in
        connectedGraphs ++ singletonGraphs


nodeBounds : Graph.NodeContext (FG.ForceNode (Node a)) () -> NodeBounds
nodeBounds nc =
    let
        x =
            nc.node.label.x

        y =
            nc.node.label.y
    in
        nc.node.label.value.bounds { x = x, y = y }


moveCard : Model -> CardDestination -> GitHubGraph.ID -> Cmd Msg
moveCard model { columnId, afterId } cardId =
    case model.me of
        Just { token } ->
            GitHubGraph.moveCardAfter token columnId cardId afterId
                |> Task.attempt (CardMoved columnId)

        Nothing ->
            Cmd.none
