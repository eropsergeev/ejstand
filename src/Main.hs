--import EjStand.DataParser
--import Text.Printf (printf)
import EjStand.ConfigParser

main :: IO()
main = do
--  parsed <- parseEjudgeXMLs $ map (printf "xmls/%d.xml") ([5501..5525] :: [Int])
  parseConfig "cfg/group-c.cfg"
