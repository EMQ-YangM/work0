{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Command where

import Data.Aeson
import Data.ByteString.Lazy as BSL
import GHC.Generics

type GraphId = Int

type NodeId = Int

type Name = String

data Node = Node
  { nodeName :: String,
    nodeId :: Int,
    nodeDescription :: Maybe String,
    nodeInputNodes :: [(Int, Int)],
    nodeScript :: String
  }
  deriving (Generic, FromJSON, ToJSON)

data Graph = Graph
  { graphName :: String,
    graphDescription :: Maybe String,
    graphNodes :: [Node]
  }
  deriving (Generic, FromJSON, ToJSON)

data Command
  = CreateGraph
      {createGraph :: Graph}
  | RemoveGraph
      {removeGarphId :: GraphId}
  | GraphCommand
      { graphId :: GraphId,
        graphCommand :: GraphCommand
      }
  | NodeCommand
      { graphId :: GraphId,
        nodeId :: NodeId,
        nodeCommand :: NodeCommand
      }
  deriving (Generic, FromJSON, ToJSON)

data GraphCommand
  = InsertNode {insertNode :: Node}
  | RemoveNode
      { nodeId :: NodeId,
        dependNodeSource :: [(NodeId, Int)]
      }
  deriving (Generic, FromJSON, ToJSON)

data NodeCommand
  = LookUpVar String
  | EvalExpr String
  deriving (Generic, FromJSON, ToJSON)

data Result
  = Success String
  | Failed String
  deriving (Generic, FromJSON, ToJSON)

type Id = Int

data Client a = Client Id a

-- >>> BSL.writeFile "careteGraph.json" (encode defCreateGraph)
defCreateGraph =
  CreateGraph
    ( Graph
        { graphName = "test",
          graphDescription = Just "something",
          graphNodes =
            [ Node
                { nodeName = "Source",
                  nodeId = 0,
                  nodeDescription = Nothing,
                  nodeInputNodes = [],
                  nodeScript = "var a = 0; function handler(){ a = a + 1; logger(a); return(1) }"
                }
            ]
        }
    )

defRemoveGraph = RemoveGraph 1

-- >>> BSL.writeFile "nodeEval.json" (encode defNodeCommand1)
defNodeCommand =
  NodeCommand
    { graphId = 1,
      nodeId = 0,
      nodeCommand = LookUpVar "a"
    }

defNodeCommand1 =
  NodeCommand
    { graphId = 1,
      nodeId = 0,
      nodeCommand = EvalExpr "a = 10"
    }
